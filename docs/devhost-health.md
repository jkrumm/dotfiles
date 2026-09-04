# Dev-host health heartbeat and upstream drift (mini only)

The full rationale behind the two monitoring surfaces on the mini. Commands and
one-line gotchas live in `CLAUDE.md`.

## The heartbeat

`scripts/devhost-health-check.sh` runs every 300 s via the
`com.jkrumm.devhost-health` LaunchAgent and pushes **three** Uptime Kuma
monitors. `MacMini Dev Host - Push` is the composite, covering **thirteen**
components:

| Component | Checks |
|-|-|
| tailscale | daemon state + node-key expiry days |
| sshd | listener present |
| herdr | server answering |
| git push credential | `op://mini/github/token` resolves (no network call) |
| dev vhosts | Cloudflare DNS module, wildcard cert days-left, DNS A-record drift, token/include permissions |
| memory | pressure level + swap as a share of RAM |
| launchd restarts | delta on `runs` for every KeepAlive job |
| boot path | plist on disk + `launchctl print` path match for every KeepAlive job |
| services | sideclaw, hermes gateway, colima, caddy, dnsmasq |
| claude auth | keychain credential, then the token fallback |
| obsidian | CLI answers (i.e. the app is running) |
| disk | free space |
| runaways | report-only CPU-time reaper |

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, and prints the runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

**It is a bash 3.2 script and must stay one.** The plist sets no `PATH`, so
launchd hands it `/usr/bin:/bin:/usr/sbin:/sbin` and `/usr/bin/env bash` is
Apple's 3.2 — no `mapfile`, no `${var,,}`, no `"${arr[@]}"` on a possibly-empty
array under `set -u`, which is why checks accumulate into newline-delimited
strings. A `brew install bash` would make the interactive run silently start
accepting constructs launchd will fail on.

**Push, not probe.** The ACL grants `tag:homelab → tag:vps` but *not*
`tag:homelab → tag:mac`, so Kuma cannot reach the mini, and an inbound grant just
for monitoring would be new attack surface for a check the mini can run itself.

**One monitor, not thirteen.** tailscale/sshd/herdr fail together when the mini
sleeps or drops off the tailnet, so separate monitors would be simultaneous pages
saying one thing; the failing component is named in the push `msg`, where the
diagnosis belongs. The rest are deliberate exceptions — a token expires, `brew
upgrade caddy` reverts a DNS module, a service crash-loops, a disk fills, all on
an otherwise healthy host — folded in anyway, because a dedicated Kuma monitor is
worth less than one more named component in the `msg`.

**The line that holds is absence, not independence.** A component that can be
legitimately *missing* on a good machine gets its own monitor, since folding it
in would page "dev host DOWN" for a feature this host lacks — collie and secrets
freshness. Merely *independent* components stay in the composite and SKIP when
unconfigured: `check_dev_vhosts` without `DEV_DOMAIN`, the service probes without
their plists, `claude auth` and the obsidian CLI without their binaries.

### Transient tolerance

The first power-cut test produced a DOWN page that was pure noise: the host
booted 08:53:20, the agent ran 08:54:24, and two agents did not start until
08:56:08 — **+2m48s, both at the same second**, a deferred launchd bootstrap pass
rather than a fault. (An earlier diagnosis said those agents "never load" and
blamed Background Task Management — wrong, they were late. Don't re-engineer two
working plists.) At `maxretries 0` that is a DOWN alert on *every* reboot.

| Knob | Default | Effect |
|-|-|-|
| `DEVHOST_BOOT_GRACE_SECONDS` | 300 | under this uptime, every failing component reports `starting` and the push stays UP |
| `DEVHOST_TRANSIENT_FAILS` | 3 | outside the grace, a check reports `degraded n/3` and FAILs only on the third consecutive run |
| `DEVHOST_REBOOT_NOTE_SECONDS` | 600 | the summary carries `host rebooted Ns ago` |

Two things that were got wrong first:

- **The boot grace covers every component, not just liveness ones.** Failures
  cascade at boot — `check_dev_vhosts` needs the tailnet IP, so it fails while
  tailscaled is merely slow — and a liveness-only grace still paged on every
  reboot.
- **The axis is level- vs edge-triggered, not liveness vs state.** A streak
  counter *permanently silences* an edge-triggered check rather than delaying it,
  which is why `check_launchd_restarts` (a delta, true for one run per restart)
  is the sole `IMMEDIATE_COMPONENTS` member.

**None of this relaxes "the machine died"** — a dead host emits no push at all
and Kuma's own missed-heartbeat is untouched, which is the property
`maxretries 0` exists to protect.

### Two checks whose obvious implementation is wrong

- **Restart detection is a delta** against
  `~/.local/state/devhost-health/launchd-runs`, never a threshold on `runs`:
  `runs` is cumulative since load, so failing on `runs > 1` pages forever over a
  `Killed: 9` from weeks ago. The alertable fact is "restarted since the last
  check" — for herdr, that every pane's processes are gone right now.
  `StartInterval` agents are excluded (there `runs` counts scheduled runs).
- **The runaway reaper gates on accumulated CPU time crossed with lifetime
  average CPU**, never instantaneous `%CPU` (a compile pegs a core) and never
  accumulated time alone (a healthy long-lived service crosses any fixed
  CPU-minute line eventually, then pages forever). `claude --bg` daemons are
  excluded by name — PPID 1 with a SourceRoot cwd is their design. It reports and
  never kills.

### One scheduler, three monitors

Collie and secrets freshness are pushed by this same agent to their **own**
monitors. A second LaunchAgent would be pure duplication; only the push target
differs, and each URL file's absence is silent by design, so a machine without
collie or without a seeded cache never fails the script.

- **Collie's check asserts behaviour, not liveness** — 200 on loopback *and* 403
  for a spoofed `Host`, both on **`/api/snapshot`**. `/` serves the SPA shell to
  any Host and always answers 200, so the same probe against `/` reports a
  healthy guard as broken. The second assertion is the point: collie's hardening
  lives in a `.env` launchd does not load on its own, so a mis-started bridge
  passes every liveness probe with its DNS-rebinding guard silently gone.
- **Secrets-cache freshness** replaced a weekly agent (Mon 09:15) under which a
  cache going stale on a Tuesday was invisible for six days — six days of
  services potentially coming up credential-less. It runs in the 300 s script and
  pushes `MacMini Secret Seed - Push` on an 8-day mtime threshold, **never
  decrypting**. That monitor's `interval: 691200` in
  `homelab/uptime-kuma/monitors.yaml` stays as-is deliberately: it is now only
  the missed-heartbeat backstop, since the script pushes DOWN explicitly at 8
  days and a dead agent shows up on the composite within ten minutes.
- **`scripts/secrets-freshness-check.sh` is NOT redundant.** The MacBook's
  auto-reseed calls it over ssh as its last step, to refresh the heartbeat the
  instant a new cache lands instead of leaving the monitor red for 5 minutes.
  `devhost-health-check.sh` has its own `secrets_freshness_detail()` and shares
  only `scripts/lib/kuma-push.sh` with it. Check `grep -rn secrets-freshness-check`
  before believing any claim that something here is dead.

### Wiring a push monitor

Fully declarative, no browser step: `make uk-sync` creates the monitor, and the
push token is retrievable in the same session via `uptime-kuma-api`
(`api.get_monitor(<id>)["pushToken"]` → `https://uptime.jkrumm.com/api/push/<token>`
into a chmod-600 file).

- `--username` defaults to `jkrumm` in `sync.py`, not `admin` — a script assuming
  otherwise fails the login and returns an empty token, not an error. Only
  `active` is genuinely unsupported for push monitors; comments claiming
  otherwise were stale and believed for months.
- **The push token lives in a chmod-600 file, not 1Password**, so monitoring
  never depends on the secrets cache being seeded.
- **`maxretries` must be 0** — time-to-DOWN is
  `interval + maxretries × retry_interval`, so the default 3 turns 10 minutes
  into 40. Kuma's interval (600 s) stays longer than the agent's cadence (300 s)
  so one skipped run does not page.
- Traps: `set -o pipefail` + `grep -q` turns a SIGPIPE into a false failure;
  `op run` masks injected secrets in its own stdout, so a remote script printing
  a full push URL returns the domain as `<concealed by 1Password>` (print the
  token alone); a LaunchAgent has no shell aliases, so `tailscale` needs an
  absolute path.

**The heartbeat asserts resolvability, not push rights** — it makes no network
call to GitHub, because at 300 s with `maxretries 0` a provider outage would page
as "dev host down". The stronger `git push --dry-run` lives in `make doctor`.
That split earned itself: the credential resolved fine on the mini while the
deployed helper still pointed at a read-only token, and only the dry-run saw it.

## Upstream drift

`make brew-upgrade` asserts its own invariants and the heartbeat fails loudly on
a broken host, but neither ever says *a pin has drifted* — so the collie plugin
sat five releases behind (two security fixes on a shell-equivalent surface) and
was found by accident, months later. `com.jkrumm.drift-check` (daily 09:40,
`scripts/drift-check.sh`) closes that; the on-demand run is part of `make doctor`.

| Command | Does |
|-|-|
| `make doctor` | Includes the drift report (read-only, no push) |
| `make drift-check-setup` | Dev-host gated: install the daily agent |
| `make drift-check-teardown` | Unload + remove |

It watches the collie commit pin (`COLLIE_REF`), the versions compiled into caddy
(`XCADDY_VERSION`, `CADDY_DNS_MODULE_VERSION`), brew-upgrade recency and pending
macOS updates. **Pins are read out of the Makefile, never duplicated.** Tag
resolution is shared with `make collie-upgrade` via `scripts/lib/github-tags.sh`:
the subtle half is `tag_commit`'s annotated-tag peel, since
`herdr plugin install --ref` pins the *dereferenced* commit and reading the tag
object's own sha reports drift no upgrade can clear.

**It reports and never upgrades, deliberately.** The hazard here is not a
compromised release, it is *silent config revert*: caddy loses its DNS module and
nothing fails for ~60 days; colima's plist reverts and nothing fails until the
next power cut. An unattended upgrader on the host running herdr, colima,
sideclaw, Hermes and every dev door is a mechanism for introducing exactly that
at 3am with nobody watching. `make collie-upgrade` is the paired human-invoked
applier (needs a TTY, refuses automation): **notice unattended, apply attended.**

Four decisions that are not arbitrary:

- **Its own scheduler**, breaking the one-scheduler rule collie and
  secrets-freshness follow: every check here is a **network call**, and the 300 s
  agent at `maxretries 0` deliberately refuses to touch GitHub. Drift moves in
  days, so daily is the cadence — and that needs its own agent.
- **Age grace, not bare "is it behind".** A drifted pin is named in the msg
  immediately but FAILs only after `DRIFT_GRACE_DAYS` (14), keyed on the
  **component, never the version** — keying on the version lets a fast-releasing
  upstream reset the clock to zero forever.
- **brew is a recency stamp, not an outdated count.** homebrew/core moves daily,
  so "something is outdated" would sit red permanently; the alertable fact is
  that the guarded upgrader has not run
  (`~/.local/state/brew-upgrade/last-success`, seeded to *now* at setup — a
  monitor whose first act is to report a fault it invented is one you disbelieve).
- **macOS is read from Apple's own cached scan**
  (`RecommendedUpdates` in `/Library/Preferences/com.apple.SoftwareUpdate`), not
  a live `softwareupdate -l` — the background scan already ran.

A network failure degrades to **`skipped`** in the msg and never to DOWN:
"GitHub was unreachable" and "you are five releases behind" are opposite
conclusions. Both paths are tested rather than asserted (backdate a `first-seen`
entry → stale, exit 1; point `GIT_BIN` at `/usr/bin/false` → every pin check
`skipped`, exit 0). The push URL file is optional and its absence silent.
**Bash 3.2**, same constraint and same reason as the heartbeat.
