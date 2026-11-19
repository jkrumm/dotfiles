# Make targets: setup, status, doctor, check

| Command | Does |
|-|-|
| `make setup` | Converge this machine onto the tracked config. Idempotent, safe to re-run. |
| `make status` | Prerequisites + symlink health, then `doctor --local`. |
| `make doctor` | Read-only health. Self-routes on the backend marker (`scripts/AGENTS.md` §Secrets). Last line: `N passed, M info — clean.` only with zero failures **and** zero warnings, else `N passed, M warnings, …`; `--json` makes it one `{"passed","failed","warnings","info"}` line. Exit 1 on a failure only. Info lines (a pending-update count the Drift monitor pages, a section that does not apply here) never count. |
| `make help` | Every target, one line each. |
| `make check` | Every target in `check:` in the Makefile: hermetic suites only (secrets lint, hook tests, script and bun tests, the architecture-check generator test). No side effects, no live probes; the live architecture-map assertion runs in `make doctor` and, softened, in `make verify`. |
| `make -k check` | `check` stops at the first failing prerequisite; `-k` runs every suite and lists all failures. |
| `make check-linux` | The Linux-safe subset (shellcheck over every tracked bash script + the portable suites): what `.github/workflows/check.yml` runs on a hosted ubuntu runner for every PR and master push. A suite joins it only after it passes there. |
| `make planned-restart` | MacBook-only: the macOS-update restart as a procedure (drain the factory queue, tell the leads, wait for merge windows and deploys, `mini-macos-update`, `recovery-check` = 0 waiting, queue run); `DRY_RUN=1` prints the steps. Automatic macOS install stays off (drift-check asserts it): `docs/devhost-health.md` §Update policy, `docs/recovery-drill.md` §4. |
| `make host-ready` | Read-only, sub-second: exit 0 when a launchd-born herdr-core answers, else one line with why and the fix. The factory's admission gate (`project.yaml` `doctor`); deliberately not `make doctor`, which takes minutes and fails on drift other leads own. |
| `make verify` | `make doctor --verify`, the repo-contract name the factory's Watch runs: fails only on what a change to this repo can break; host conditions and other leads' drift (an unmapped or unregistered agent of another owner, a stale map row, an unclassified TCC program, a DOWN Kuma monitor) are WARN. `make doctor` fails all of it. |
| `make storage-status` | Shares, mounts, free space, keepalive grade, external volume, mirror and restic age; `ARGS=--json` is the contract in `docs/storage.md` §Status. Read-only, bounded; `make doctor` WARNs from it. |
| `make logs` | Bounded tail of `~/Library/Logs/{devhost-health,…}.log`, then exits. |
| `make mini-prune` | Mini: lists, with `ARGS=--apply` removes, the plist of every disabled job and every stopped container no registry row names (`docs/mini-registry.md`). |
| `make deploy` | `make setup` under the repo-contract name; prints what it does. On the mini it then runs `scripts/gate-pin-notice.sh` (`scripts/AGENTS.md` §Deploy gate pins). |
| `make worktree-audit` / `worktree-prune` | List / reclaim clean, fully-merged git worktrees across `~/SourceRoot` + `~/IuRoot` — they pile up in four different parent dirs (repo-local, `.claude/worktrees/`, `~/IuRoot/worktrees/`, `~/IuRoot/.wt/`), so it asks git rather than assuming a location. |

`make doctor` on **both** machines: LaunchAgent grading, the architecture-map
assertion, the brew report, a worktree-audit nudge. **Mini** adds drift (no push)
and names the heartbeat rather than running it (it always pushes). **MacBook** adds the remote path
(Tailscale, ssh, the core link `hc machine ls`, GitHub credential), Kuma monitor states, then recurses into the
mini's doctor over ssh — `--local` skips that. Read-only by construction.

**Exit codes are graded.** `78` (EX_CONFIG) always fails — the job can never
start, so KeepAlive retries forever with nothing reporting it. Any other non-zero
exit fails only if the plist sets `KeepAlive` **and** the job is not running
(`db-tunnel` exits `255` on every lid-close while healthy). Also flags `/tmp`
logs, missing programs and plaintext credentials.


### Heartbeat targets (mini only)

| Command | Purpose |
|-|-|
| `make devhost-health-setup` / `-check` / `-teardown` | The 300 s composite heartbeat. `-check` runs it once, per-component. |
| `make mini-apps-setup` / `-restart` / `-teardown` / `-check` / `-test` | The apps page control endpoint (`mini-apps/`, `com.jkrumm.mini-apps`, `127.0.0.1:7797`) and the 120 s idle stop (`com.jkrumm.mini-apps-idle`): start, stop and wake of registry services; `docs/mini-registry.md` §Apps page |
| `make kuma-door-setup` / `-restart` / `-teardown` / `-gen` / `-check` | The Kuma door (`kuma-door/AGENTS.md`): one tailnet port Kuma pulls service health through; `-gen` writes the monitors from the registry |
| `make drift-check-setup` / `-teardown` | Retires the old drift agent (run by `make setup`); drift is now a daily bounded side job of the heartbeat |
| `make agent-setup` / `agent-status` / `agent-uninstall` | Both machines: build and install the pinned host-agent collector (`agent/`), load `com.jkrumm.host-agent`; status is the doctor's host-agent section. `docs/host-agent.md` |
| `make doctor` | The on-demand read-only view, including drift without pushing |
