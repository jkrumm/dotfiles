# Dev-host health heartbeat and upstream drift (mini only)

Condensed reference lives in `CLAUDE.md` → "Dev-host health heartbeat" and
"Upstream drift". This is the full rationale.

## Dev-host health heartbeat (mini only)

**Three** Uptime Kuma push monitors, one agent. `MacMini Dev Host - Push` (group
`Local`) is the composite and covers **thirteen** components: tailscaled (state
*and* node-key expiry days), sshd, herdr, mosh (both the binary and its
Application Firewall allowlist membership), the GitHub push credential, the clean
dev-vhost door (`check_dev_vhosts` — the Cloudflare DNS module, wildcard cert
lifetime, DNS A-record drift, and token/include file permissions; see *Two
dev-server doors* above), memory pressure + swap, launchd restart counts, six
always-on services (sideclaw, litellm, hermes gateway, colima, caddy, dnsmasq),
`claude auth status`, the obsidian CLI, disk, and a report-only runaway reaper.
`MacMini Collie - Push` and `MacMini Secret Seed - Push` are separate — see **One
scheduler, three monitors** below for why. All three are driven by
`scripts/devhost-health-check.sh` via the `com.jkrumm.devhost-health` LaunchAgent
every 5 minutes. Opt-in per machine like `remote-access`:

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, and prints the ordered runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

**It is a bash 3.2 script and must stay one.** The plist sets no `PATH`, so
launchd hands it `/usr/bin:/bin:/usr/sbin:/sbin` and `/usr/bin/env bash` resolves
to Apple's 3.2. No `mapfile`, no `${var,,}`, and no `"${arr[@]}"` on a
possibly-empty array (3.2 calls that an unbound variable under `set -u`), which
is why the newer checks accumulate into strings rather than arrays. The mini has
no Homebrew bash today, so an interactive `make devhost-health-check` also runs
3.2 — but that is machine state, not a guarantee: `brew install bash` and the
interactive run silently starts accepting constructs launchd will fail on.

**Push, not probe** — the ACL grants `tag:homelab → tag:vps` but *not*
`tag:homelab → tag:mac`, so Uptime Kuma physically cannot reach the mini.
Opening an inbound grant purely for monitoring would be new attack surface for a
check the mini can report on itself over the already-granted outbound path. Same
pattern as `MacMini Secret Seed - Push` and the Hermes monitors.

**One monitor, not thirteen.** herdr/sshd/tailscaled/mosh all fail together when
the mini sleeps or drops off the tailnet; separate monitors would be simultaneous
pages saying one thing. The failing component is named in the push `msg`, which
is where the diagnosis belongs. The other nine are all deliberate exceptions to
that rule — a token expires, `brew upgrade caddy` reverts a DNS module, a cert
nears expiry, an A record drifts, a service crash-loops, an OAuth token lapses, a
disk fills — each while the rest of the host is perfectly healthy. Every one was
folded in anyway, because a dedicated Kuma monitor is worth less than one more
named component in the `msg`.

**The line that does hold is absence, not independence.** A component that can be
legitimately *missing* on a good machine gets its own monitor, because folding it
in would page "dev host DOWN" for a feature this host does not have — that is
collie and secrets freshness. A component that is merely *independent* stays in
the composite and SKIPs when unconfigured: `check_dev_vhosts` without
`DEV_DOMAIN`, the six service probes without their plists, `claude auth` and the
obsidian CLI without their binaries, and the Tailscale key-expiry sub-check once
WP1 disables expiry entirely (an empty `KeyExpiry` is the correct steady state,
so it skips silently and permanently rather than nagging).

**Transient tolerance (2026-08-01).** The first real power-cut test produced a
DOWN page that was pure noise: the host booted 08:53:20, the agent ran 08:54:24,
and sideclaw + linewatch-collector did not start until 08:56:08 — **+2m48s, both
at the same second**, a deferred launchd bootstrap pass rather than a fault. With
`maxretries 0` that is a full DOWN alert on *every* reboot, and a monitor that
cries wolf after every power blip trains you to ignore it. (An earlier diagnosis
said those two agents "never load" and blamed Background Task Management — wrong;
they were only late. Don't re-engineer two working plists.) Three knobs, all
env-overridable: `DEVHOST_BOOT_GRACE_SECONDS` (300 — every failing component
reports `starting`, push stays UP), `DEVHOST_TRANSIENT_FAILS` (3 — outside the
grace a check reports `degraded n/3` and only FAILs on the third consecutive
run), `DEVHOST_REBOOT_NOTE_SECONDS` (600 — the summary carries `host rebooted Ns
ago`, closing the gap where a 3am power cut that recovered perfectly left no
trace anywhere).

Two things that were got wrong first: **the boot grace covers every component,
not just liveness ones** — failures cascade at boot (`check_dev_vhosts` needs the
tailnet IP, so it fails while tailscaled is merely slow), so a liveness-only
grace still paged on every reboot. And **the axis is level- vs edge-triggered,
not liveness vs state** — a streak counter silences an edge-triggered check
*permanently* rather than delaying it, which is why `check_launchd_restarts` (a
delta, true for one run per restart) is the sole `IMMEDIATE_COMPONENTS` member.
**None of this relaxes "the machine died"** — if the host is gone no push lands
and Kuma's own missed-heartbeat is untouched, which is the property `maxretries
0` exists to protect.

**Two of the new checks are worth knowing the shape of, because the obvious
implementation of each is wrong.** Restart detection is a **delta** against a
state file (`~/.local/state/devhost-health/launchd-runs`), not a threshold on
`runs` — `runs` is cumulative since load, so failing on `runs > 1` would page
forever over herdr's `Killed: 9` from weeks ago; the alertable fact is "restarted
since the last 5-minute check", which for herdr means every pane's processes are
gone right now. And the runaway reaper gates on **accumulated CPU time crossed
with lifetime average CPU**, never instantaneous `%CPU` (a compile pegs a core)
and never accumulated time alone (a healthy sideclaw crosses any fixed
CPU-minute line given enough uptime, then pages forever). `claude --bg` daemons
are excluded by name: they are PPID 1 with a SourceRoot cwd by design. It reports
and never kills.

**One scheduler, three monitors.** Collie is deliberately *not* a composite
component, and the reason is the rule above pointed the other way: it is opt-in
per machine and can be absent, down or mis-hardened while herdr/sshd/tailscaled/
mosh are all fine — so folding it in would mark the dev host DOWN and implicate
healthy components. It gets `MacMini Collie - Push` instead. What it does *not*
get is its own agent: the existing LaunchAgent already runs every 300s, so a
second one would be pure duplication. Only the push target differs, and the URL
file's absence is silent by design so a machine without collie never fails the
script.

Collie's check asserts **behaviour, not liveness** — the bridge answers 200 on
loopback *and* a spoofed `Host` header must return 403, both on
**`/api/snapshot`**. Naming the path is not pedantry: `/` serves the SPA shell to
any Host and always answers 200, so the same probe run against `/` reports a
perfectly healthy guard as broken. That second assertion is the whole point:
collie's hardening lives in a `.env` that launchd does not load on its own, so a
mis-started bridge passes every liveness probe with its DNS-rebinding guard
silently gone. `launchctl list` says status 0 and the UI works. Only the
behavioural check sees it.

**Secrets-cache freshness is the second case, and it moved here from a weekly
agent.** `com.jkrumm.secrets-freshness` fired once a week (Mon 09:15), so a cache
going stale on a Tuesday was invisible for six days — six days of services
potentially coming up credential-less with nothing reporting it. The check now
runs in the 300s script and pushes `MacMini Secret Seed - Push` (8-day threshold,
mtime only, never decrypts), on exactly collie's terms: its own monitor because a
stale cache does not fail with tailscaled/sshd/herdr, and a silent skip when
`~/.config/secrets/freshness-push-url` is absent. The weekly LaunchAgent was the
duplicate and is **torn down** on the mini (2026-08-17, `make
secrets-freshness-teardown`; the target stays for a machine that wants it back).

**`scripts/secrets-freshness-check.sh` is NOT redundant — this file claimed it
was for weeks, and acting on that would have broken the reseed.** It is what the
MacBook's auto-reseed calls over ssh (`make secrets-freshness-check`) as its last
step, to refresh the heartbeat the instant a new cache lands instead of leaving
the monitor red for up to 5 minutes. `devhost-health-check.sh` has its own
`secrets_freshness_detail()` and shares only `scripts/lib/kuma-push.sh` with it.
Two callers, one of them remote — check `grep -rn secrets-freshness-check` before
believing any claim that something here is dead.

The monitor's `interval: 691200` in `homelab/uptime-kuma/monitors.yaml` was sized
for the weekly pusher and is left alone deliberately: it is now only the
missed-heartbeat *backstop*, since the 300s script pushes DOWN explicitly the
moment the cache crosses 8 days, and a dead agent shows up on `MacMini Dev Host -
Push` (interval 600) in ten minutes rather than eight days.

**Push monitors are fully declarative — no browser step.** `make uk-sync`
creates them, proven on 2026-07-28 when it created `MacMini Collie - Push`
(id=205) against `uptime-kuma:2` with `uptime-kuma-api` 1.2.1. The push token is
retrievable in the same session, so create-and-wire is one scripted pass:

```bash
# on homelab, monitor id from the uk-sync output
op run --env-file=.env.tpl -- uptime-kuma/.venv/bin/python -c \
  'import os; from uptime_kuma_api import UptimeKumaApi
   api=UptimeKumaApi("http://localhost:3010")
   api.login("jkrumm", os.environ["UPTIME_KUMA_PASSWORD"])
   print(api.get_monitor(<id>)["pushToken"])'
# → https://uptime.jkrumm.com/api/push/<token> into a chmod-600 file
```

Note `--username` defaults to `jkrumm` in sync.py, not `admin` — an ad-hoc
script that assumes otherwise fails the login and returns an empty token rather
than an error. Only `active` is genuinely unsupported for push monitors.

Seven comments in `homelab/uptime-kuma/monitors.yaml` and one in `sync.py`
asserted the opposite for months. They were stale, believed, and reasoned
from — all now corrected. Treat a "this isn't supported" comment as a claim to
re-test, not a constraint, especially where the call site says otherwise.

**The heartbeat asserts resolvability, not push rights** — and says "credential
ready", not "push ready", on purpose. It makes no network call to GitHub, because
at a 300s cadence with `maxretries 0` a GitHub outage or a flaky link would page
as "dev host down". The stronger claim costs a real `git push --dry-run`, so it
lives in the on-demand `make remote-dev-doctor` instead. That split has already
earned itself: on 2026-07-26 the credential resolved fine on the mini while the
deployed helper still pointed at Hermes's read-only token, and only the doctor's
dry-run saw it.

The push token lives in a chmod-600 `~/.config/uptime-kuma/devhost-push-url`,
not 1Password, so monitoring never depends on the secrets cache being seeded — a
stale cache would otherwise take the monitor down with it. Kuma's monitor
interval (600s) must stay longer than the agent's cadence (300s) so one skipped
run doesn't page. **`maxretries` must be 0**: time-to-DOWN is
`interval + maxretries × retry_interval`, so inheriting the default 3 would page
at 40 minutes, not 10 — the other push monitors in `monitors.yaml` still do.
Three traps worth remembering, all hit while building this:
`set -o pipefail` + `grep -q` turns a SIGPIPE into a false failure; `op run`
masks injected secret values in its *own* stdout, so a remote script that prints
a full push URL returns the domain as `<concealed by 1Password>` (print the token
alone and assemble the URL locally); and a
LaunchAgent has no shell aliases — `tailscale` is an alias to the app bundle and
must be called by absolute path.

## Upstream drift (mini only)

**Two halves of the update story were built and the middle was missing.**
`make brew-upgrade` is a guarded upgrader that asserts its own invariants;
the heartbeat above fails loudly on a broken host. Neither ever says *a pin
has drifted* — so the collie plugin sat **five releases behind** (0.17.0 →
0.22.0, two of them security fixes on a shell-equivalent surface) and was
found by hand, months later, by accident. `make drift-check` closes that.

| Command | Does |
|-|-|
| `make drift-check` | Run once, print per-component drift. Read-only. |
| `make drift-check-setup` | Dev-host gated: install `com.jkrumm.drift-check` (daily 09:40) |
| `make drift-check-teardown` | Unload + remove |

It watches what nothing else does: the commit pin (`COLLIE_REF`), the version pins compiled into caddy (`XCADDY_VERSION`,
`CADDY_DNS_MODULE_VERSION`), brew-upgrade recency, and pending macOS updates.
Pins are read out of the **Makefile**, never duplicated.

Tag resolution is shared with `make collie-upgrade` via
`scripts/lib/github-tags.sh` rather than copied. The subtle half is
`tag_commit`'s annotated-tag peel: `herdr plugin install --ref` pins the
*dereferenced* commit, so reading the tag object's own sha instead reports drift
that no upgrade can ever clear — and a second copy of that logic is a second
chance to get it backwards, in the one place where wrong looks exactly like
right.

**It reports and never upgrades, deliberately.** The hazard on this machine is
not a compromised release — `brew-upgrade.sh`'s header settles that — it is
*silent config revert*: caddy loses its DNS module and nothing fails for ~60
days; colima's plist reverts and nothing fails until the next power cut. An
unattended upgrader on the host that runs herdr, colima, sideclaw, Hermes and
every dev door is a mechanism for introducing exactly that at 3am with nobody
watching. Same trade as the caddy/mosh pins, and as the runaway reaper's refusal
to kill.

That stays true with `make collie-upgrade` in the tree, and the pair is the whole
point: **notice unattended, apply attended.** The applier is human-invoked, needs
a TTY, and refuses to run from automation — it removes the tedium of upgrading,
never the decision.

Four decisions that are not arbitrary:

- **Its own scheduler**, breaking the "one scheduler, N monitors" rule collie
  and secrets-freshness follow. Every check here is a **network call**, and the
  300s agent runs `maxretries 0` and deliberately refuses to touch GitHub for
  exactly that reason — a provider outage would page as "dev host down". Drift
  moves in days; daily is the right cadence and it needs its own agent to have
  one.
- **Age grace, not bare "is it behind".** A drifted pin is named in the msg
  immediately but only FAILS after `DRIFT_GRACE_DAYS` (14). The 1Password backup
  monitor already taught this: it "had spent large stretches red as a nag, which
  is how you train yourself to ignore it". The clock is keyed on the
  **component, never the version** — keying on the version lets a fast-releasing
  upstream reset it to zero forever.
- **brew is a recency stamp, not an outdated count.** homebrew/core moves daily,
  so "something is outdated" is true almost always and would sit red
  permanently. The alertable fact is that the *guarded upgrader has not run* —
  `brew-upgrade.sh` writes `~/.local/state/brew-upgrade/last-success`, and
  `drift-check-setup` seeds it to *now* rather than leaving it absent, because a
  monitor whose first act is to report a fault it invented is one you learn to
  disbelieve.
- **macOS is read from Apple's own cached scan** (`defaults read
  /Library/Preferences/com.apple.SoftwareUpdate RecommendedUpdates`), not
  `softwareupdate -l` — the background scan already ran, so the answer is in a
  plist and costs nothing instead of tens of seconds and a network round trip.

A network failure degrades to **`skipped`** in the msg and never to DOWN;
"GitHub was unreachable" and "you are five releases behind" are opposite
conclusions and only one of them is your problem. Both paths are tested rather
than asserted — backdate a `first-seen` entry and it goes stale and exits 1;
point `GIT_BIN` at `/usr/bin/false` and all four pin checks report `skipped`
with exit 0. The push URL file is optional and its absence silent, same contract
as the collie and secrets monitors, so the agent is useful on a machine with no
Kuma wiring at all.

**Bash 3.2**, same constraint and same reason as `devhost-health-check.sh`: the
plist sets no PATH, launchd hands over `/usr/bin:/bin:/usr/sbin:/sbin`, and
`/usr/bin/env bash` there is Apple's 3.2. Newline-delimited strings, never
arrays.

