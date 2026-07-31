# Mini headless detach — human checklists

Companion to `mini-headless.md`, which holds the reasoning. This file holds only the
steps a human must perform, in order, because they need sudo, biometric approval, or a
GUI dialog. Agent-executable work is not listed here.

State as of 2026-07-31: WP3 executed (two cores and 9.8 GB of swap reclaimed, 9 orphan
herdr servers reaped). Lane 1 packages executed by agents — see the git log.

**Ordering rule.** WP1 and WP2 come first and nothing else starts until WP2 passes.
**WP4 must complete before WP6** — auto-login does not unlock the login keychain, so
Claude Max auth has to be off the keychain before the FileVault switch or every agent
silently falls back to API billing. WP17 (detach) is gated on WP2, WP4, WP6, WP7, WP8
and WP14 all passing.

---

## Lane 2 — from the MacBook (sudo over ssh, biometric)

Sudo on the mini is deliberately MacBook-only (`op://Private/mac-mini-server/password`,
refused unconditionally by the mini's cache). Every step here runs from the MacBook:

```bash
ROOT_PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm) && \
  ssh mini "echo '$ROOT_PW' | sudo -S <cmd>"
```

`sudo -S` reads stdin, so none of these need `ssh -t` — which matters, because a
`!`-prefixed Claude Code command gets no TTY.

### L2.1 — WP1: disable Tailscale key expiry (DO THIS FIRST)

Browser, Tailscale admin console → Machines → ⋯ → Disable key expiry.

| Device | Expires | Days | Note |
|-|-|-|-|
| `localhost` (phone) | 2026-08-05 | **5** | collie access dies with it |
| `IUGMXK9P6DY1XC` | 2026-08-05 | **5** | work machine |
| `TB330FU` (tablet) | 2026-08-19 | 19 | holds `tag:tablet` dev-door grant |
| **`mini`** | **2026-10-10** | **71** | **recovery needs a browser ON the mini — i.e. a monitor, physically reattached** |
| `apple-tv` | 2026-10-09 | 70 | optional |
| `TV` | 2026-11-16 | 108 | optional |

The mini is the one that cannot be recovered remotely. The two 5-day entries are more
urgent in wall-clock terms and were not in the original plan's table — do all of them.

Verify:
```bash
ssh mini '/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["KeyExpiry"])'   # expect: None
```

### L2.2 — WP2: prove break-glass (MacBook half)

1. `make remote-dev-doctor` — expect 10/10.
2. Confirm Screen Sharing over the tailnet: `vnc://mini`. **State its limit in the
   runbook:** it needs an already-logged-in GUI session and is useless at a FileVault
   pre-boot screen. This is why break-glass is coupled to the FileVault decision.
3. After the mini-side logout test (L3.2), from here: `tailscale ping mini` and
   `ssh mini` must both succeed **while the mini sits at the login window**.

### L2.3 — WP5: power-on layer

Currently `autorestart 0` and `Automatic Restart on Power Loss: No` — mains returns,
machine stays off.

```bash
sudo pmset -a autorestart 1 && sudo pmset -a autorestartatconnect 1
sudo pmset -a powernap 0
```

Both keys are settable per `pmset -g cap` on this Mac14,12 / macOS 26.5.2 — verified.
`autorestartatconnect` is laptop-oriented and redundant on a battery-less mini but
harmless. `powernap` only acts during sleep and this machine has `sleep 0`, so it is
dead configuration surface.

**Leave alone:** `womp 1`, `tcpkeepalive 1` (0 disables wake-for-network),
`ttyskeepawake 1` (herdr/mosh sessions are ttys), `sleep 0`. One dependency worth
remembering: `powerd`'s `PreventUserIdleSystemSleep` assertion is named "Prevent sleep
while display is on" and **disappears when the monitor is detached**, after which
`sleep 0` is the only thing keeping the machine awake. Do not relax it.

Acceptance — check this, not just `pmset -g custom`:
```bash
ssh mini "system_profiler SPPowerDataType | grep 'Power Loss'"   # expect: Yes
```

### L2.4 — WP7: remove dead system-domain plists

User-domain dead plists were handled by the agent run. These need sudo:

```bash
sudo launchctl bootout system/com.macromates.auth_server 2>/dev/null
sudo mv /Library/LaunchDaemons/com.macromates.auth_server.plist /Library/LaunchDaemons/.disabled-20260731/
sudo mv /Library/LaunchAgents/com.microsoft.SyncReporter.plist /Library/LaunchAgents/.disabled-20260731/
```

`com.macromates.auth_server` is a root privileged helper for a TextMate that is already
deleted — dead root attack surface. `com.microsoft.SyncReporter` has an empty
`ProgramArguments`. Move aside rather than delete: reversible, and the app can
re-register if the mini ever goes headful again.

Also install the caddy wait-for-address wrapper designed in the agent run — the daemon
plist lives in `/Library` and cannot be touched from the mini. Exact commands are in the
agent's report; the defect is that `Caddyfile.d/tailnet.caddy` hardcodes
`bind 100.87.73.3` while caddy starts pre-login and the tailnet address is created by
the Tailscale GUI app at login. It is a **bounded** outage (launchd retries on a 10 s
throttle, so caddy self-heals ~10 s after the utun address appears), not a permanent
one — fix it, but do not treat it as the blocker.

### L2.5 — WP8: system-domain bootouts (vendor updaters)

Nothing is uninstalled. This only stops things starting. Move each plist aside after
booting it out, so it is reversible.

| Item | Location |
|-|-|
| Microsoft AutoUpdate helper, OneDrive ×2 updaters, Office licensing, Teams updater | `/Library/LaunchDaemons` |
| Logitech G HUB agent + updater daemon | `/Library/LaunchAgents`, `/Library/LaunchDaemons` |
| Zoom root daemon, Amazon acvc helper | `/Library/LaunchDaemons` |

```bash
sudo launchctl bootout system/<label>
sudo mkdir -p /Library/LaunchDaemons/.disabled-20260731
sudo mv /Library/LaunchDaemons/<plist> /Library/LaunchDaemons/.disabled-20260731/
```

Acceptance: `launchctl list | awk '$2 != 0 && $2 != "-"' | grep -v com.apple.` returns
nothing.

### L2.6 — WP11: reseed the secrets cache

Any ref migration needs `make secrets-seed` from the MacBook **before** the consumer is
switched, or the service comes up credential-less. `secrets-run` fails closed, so a
half-done migration is loud rather than silent.

```bash
cd ~/SourceRoot/dotfiles-private && git pull     # the seed reads the LOCAL headless.refs
cd ~/SourceRoot/dotfiles && make secrets-seed    # biometric, one pass
```

**The `git pull` is not optional.** A ref added on the mini and left unpushed is silently
omitted from the seed.

Refs to add before seeding (from the agent reports):
- `op://mini/claude/oauth-token` — WP4, minted in L3.3. **The ref line and its
  T-classification note are already written into `dotfiles-private/headless.refs`, and the
  security-review section into `docs/security-review.md` — both UNCOMMITTED in the working
  tree on the mini.** Two consequences, and the second is the one that bites: an
  uncommitted edit is trivially lost by a stray `git checkout`, and an *unpushed* one is
  silently omitted from a seed run on the MacBook. Commit and push them from the mini in
  the same sitting as `claude setup-token`, and not before the 1Password item exists.
- A GitLab PAT, if the 16 IuRoot repos' credential path is being fixed this round.

Already-running processes keep their old env. After the reseed:
```bash
ssh mini 'launchctl kickstart -k gui/501/ai.hermes.gateway'
ssh mini 'launchctl kickstart -k gui/501/com.litellm.proxy'
ssh mini 'launchctl kickstart -k gui/501/com.jkrumm.sideclaw'
ssh mini 'launchctl kickstart -k gui/501/herdr.collie'
```

Then rotate the `KSWP_ARGO_TOKEN` and `ARGO_TOKEN` bearer tokens that were sitting in
plaintext in the walkingpad and usage-tracker plists.

### L2.7 — WP15: verify the LiveSync E2E passphrase is backed up

The "backed up nowhere" claim was refuted — `op item list --vault homelab` returns an
item titled `couchdb`. The narrow real question is whether the **end-to-end encryption
passphrase** (`encryptedPassphrase` in the vault's `data.json`, distinct from the CouchDB
HTTP password) is in that item's `notesPlain`:

```bash
op item get couchdb --vault homelab --account tkrumm --format json | jq -r '.fields[]? | select(.label=="notesPlain") .value'
```

Add it if absent. Cannot be checked from the mini — `op` hangs there.

---

## Lane 3 — physically at the mini

Do these while a screen is still attached. Every one of them needs a GUI dialog answered
or a keyboard at the machine.

### L3.1 — WP2: fit the break-glass kit

1. Fit the **HDMI dummy plug** (~5 EUR passive EDID emulator). A Dell U4919DW has been
   attached continuously since Jul 24, so the no-EDID case has **never** been exercised
   on this box, and Obsidian is Electron. The two audits disagree on whether macOS
   synthesises a usable framebuffer without EDID and neither is verified — at 5 EUR the
   plug makes the question moot.
2. Enable Tailscale **"Run unattended"** in the menu bar (macsys build only).
3. Confirm the physical recovery kit is reachable in minutes: spare monitor, keyboard,
   cable.

### L3.2 — WP2: the logout test (do it correctly)

**Log OUT and leave the mini at the login window. Do NOT reboot.** With FileVault on
there is no "booted but not logged in" state reachable by rebooting, so a reboot test
silently measures the logged-in case and returns a false pass.

Then from the MacBook: `tailscale ping mini` and `ssh mini` must both succeed.

This is also the first real evidence that Tailscale runs before login on this machine —
the macsys variant *should* per Tailscale's own variants table, but that is a product
claim, not an observation of this box.

Also, with root:
```bash
sudo sfltool dumpbtm > /tmp/btm.txt     # returns zero bytes without root
```
SMAppService background items are the single enumeration gap in the entire audit. Diff
against the legacy login-item list (`Jiggler`, `Raycast`, `Clawbar`).

**Nothing else starts until this passes.**

### L3.3 — WP4: take Claude Max auth off the login keychain

**Mandatory, and it must land before WP6.** Highest-leverage step in the plan: it
dissolves the `rd bg`-through-a-herdr-pane workaround, makes `ssh mini 'claude --bg …'`
correct, unblocks sideclaw-as-daemon, and removes the one thing auto-login demonstrably
cannot provide.

**The agent half is DONE. Only steps 1, 3-commit and 4 below are left, and all three need
a human.** Wired and verified 2026-07-31:

- `config/zsh/claude-auth.zsh` — a `claude()` zsh function that resolves
  `op://mini/claude/oauth-token` through `secrets-run` and hands it to the binary as
  `CLAUDE_CODE_OAUTH_TOKEN`. Self-gates on the `cache` backend so it never fires on the
  MacBook (where `secrets-run` passes through to biometric `op` and would prompt on every
  launch). Falls through silently while the ref is absent, so today's keychain login is
  untouched — verified, `claude auth status` still returns `loggedIn: true` here.
- `_setup-zshenv` now appends a second guarded block sourcing that file from `~/.zshenv`,
  which is the **only** startup file `ssh mini 'claude --bg …'` reads. Applied and
  idempotent-checked; a non-interactive `zsh -c 'whence -w claude'` reports `function`.
- Proven with a stubbed `secrets-run` + `claude`: the token reaches the child in its
  environment and **not** in its argv (prefix assignment, not `env VAR=… claude` — `env`
  puts the value where `ps auxww` shows it).
- The drafted `headless.refs` entry and `docs/security-review.md` section are written into
  the `dotfiles-private` **working tree, uncommitted** — see the warning in L2.6.

Remaining, human-only:

1. `claude setup-token` from a present-human session on the mini. Store the value as
   `op://mini/claude/oauth-token`. **Create the 1Password item before committing the ref** —
   the seed reads every ref and fails closed, so a listed ref with no item breaks the whole
   reseed, not just that line.
2. Commit + push `dotfiles-private` (the two drafted files).
3. Reseed from the MacBook (L2.6) — `git pull` there first, it is not optional.

Env-var name is already confirmed against the shipped CLI (2.1.220): `CLAUDE_CODE_OAUTH_TOKEN`,
never `ANTHROPIC_API_KEY`.

Three facts about this token, researched rather than assumed, that the drafts record in full:
its scope is **`user:inference` alone** — narrower than the `/login` credential in the keychain
today, so this is a scope *reduction*; it lives **one year with no refresh**; and it has **no
reliable server-side revocation** (`/logout` and the claude.ai settings page are client-side
only). The 1-year expiry is safe only because `check_claude_auth` in
`scripts/devhost-health-check.sh` fails the 5-minute heartbeat the day it lapses. That check is
**live today**, not skipping.

Do **not** drop the herdr-pane indirection in `remote-dev.sh` `cmd_bg` yet — that change is
explicitly gated on the acceptance test below passing, and it has not been run.

Acceptance, from the MacBook:
```bash
ssh mini 'claude --bg "echo ok"'
```
The daemon must report `loggedIn: true`, `subscriptionType: max` — **not**
`Not logged in`. That failure is silent: it still lists healthy in `claude agents` while
billing API credits.

### L3.4 — WP6: disable FileVault, enable auto-login

**Gated on L3.3 passing.** On Apple Silicon `fdesetup disable` is a Secure Enclave
key-rewrap, not a bulk decryption pass over 672 GB — effectively instantaneous, no data
loss. The internal SSD stays encrypted either way; FileVault only controls what wraps the
key.

What you give up, precisely: someone with physical possession can press the power button
and get a logged-in desktop. That desktop holds `~/.config/sops/age/keys.txt` (189 B,
0600), which decrypts all 136 cached refs. Offline NAND extraction, recoveryOS and Target
Disk Mode all remain gated; a DFU restore wipes the disk rather than exposing it.

1. `sudo fdesetup disable` — needs an interactive volume-owner password prompt, so it
   cannot be scripted headlessly. `jkrumm` has a Secure Token and is a volume owner
   (verified), so it will succeed.
2. `sudo sysadminctl -autologin set -userName jkrumm` — the supported mechanism. Do
   **not** hand-write `/etc/kcpassword`.
3. Reboot. Decisive test from the MacBook: start an `rd bg` agent and check
   `claude auth status` returns `loggedIn: true, subscriptionType: max`. Expect the login
   keychain itself to be **locked** — that is exactly what WP4 makes survivable.
4. Decide the three console-security settings explicitly rather than inheriting undeclared
   defaults:
   - `askForPassword` — neither `com.apple.screensaver` nor its ByHost variant declares it
     today.
   - Screen Sharing → "Allow access for → only these users → jkrumm".
   - Clear the legacy `/Library/Preferences/com.apple.VNCSettings.txt` (32 bytes, dated
     Jun 11) — CLAUDE.md says the VNC password should be off.
5. Verify the ACL's `dst` for :5900 is not `tag:mac`-wide, with `tag:client` (two TVs +
   tablet) one mis-scoped grant away. Currently rule 0 grants (5900,5900) from the mini
   and the MacBook only — correctly scoped. Re-check after any ACL push.

Acceptance: **power-cycle at the wall.** Machine comes back; `ssh mini` works;
`claude agents` lists a healthy agent on `max` billing; `herdr session list` responds;
`vnc://mini` shows a desktop.

Rollback: `sudo fdesetup enable` + `sudo sysadminctl -autologin delete`. Re-enabling does
run a real encryption pass and takes time — the asymmetry is expected.

### L3.5 — WP8: System Settings toggles

Nothing is uninstalled. Apps stay on disk so the mini can be a headful workstation again.
The Brewfile is **not** edited — it keeps describing the machine truthfully and
`make brew-check` keeps passing.

**Login Items & Extensions** (System Settings → General):
- Remove login items: `Jiggler` (not even running; its purpose is already served by
  `pmset sleep 0`), `Raycast`, `Clawbar`, and Spotify's `StartupHelper.app`.
  Expect `osascript … delete login item "Clawbar"` to **fail** with "Can't get login
  item" — a modern app that self-registers at first launch uses SMAppService, which never
  appears in the legacy list. It is a System Settings action, not a CLI one.
- **Network Extensions:** turn off RadioSilence
  (`com.radiosilenceapp.client.NetworkExtension`, PID 567, `[activated enabled]`, app
  already deleted from /Applications, LaunchAgent respawn-looping on `EX_CONFIG (78)`).
  Stated accurately: an orphaned, unconfigurable content-filter extension is loaded in
  the network path — not "filtering all traffic" (0.0% CPU, 16 MB, no configuration
  proven). **This is the prime suspect for any future unexplained network failure** on a
  host where Tailscale, the Funnel, the caddy dev doors and headless git push all
  traverse the stack. Try `systemextensionsctl gc` first — it garbage-collects orphaned
  extensions and is not SIP-gated, which is exactly this case. Then bootout and move
  aside `/Library/LaunchAgents/com.radiosilenceapp.agent.plist`.
- **Driver Extensions:** turn off Karabiner-Elements and Logitech G HUB (3 total). SIP is
  **enabled**, so `systemextensionsctl uninstall` will refuse — do not disable SIP for
  this. Keep the tracked `config/karabiner/karabiner.json`: the Caps-Lock→Hyper remap only
  ever applied to a keyboard attached to *this* Mac, and over `dev`/`desk` the keys are
  handled on the MacBook.

**Set a static wallpaper.** `WallpaperAerialsExtension` (PID 703) has burned 5.2% of a
core for the entire uptime animating a desktop nobody is looking at, and its assets are
2.3 GB.

> **Chrome and Helium are in active human use during the transition** and both came
> straight back after being quit (Chrome twice — once as a Keystone update self-restart,
> once by you). Do not treat "quit it" as done for these two until the transition is
> over. The consequence for WP10 is that 2.0 GB of `~/Library/Caches/Google` and 2.3 GB
> of `~/Library/Caches/net.imput.helium` stay unreclaimed — deleting mmap'd cache under
> a live browser is exactly the failure the plan warns about. `~/Library/Caches/ms-playwright`
> (1.0 GB) is separately pinned by 16 live `chrome-devtools-mcp` instances.

**Quit and de-login-item, keep installed:** Microsoft Teams (currently burning a full
core — argo reads Teams server-side via M365, not the desktop app), Spotify, Claude.app
(agents use the CLI at `~/.local/bin/claude`), Raycast (the battery-limiter Script
Commands are MacBook-only and self-gate on an internal battery), TickTick (Hermes and
argo use the cloud API; a grep of `hermes-agent` for `osascript|open -a` returned zero
hits), WhatsApp, MacWhisper, cmux, Ghostty, DevUtils, Riot Client. Close the stray
Calendar, Notes, Preview, System Settings and Terminal windows.

> **Before quitting Teams / WhatsApp / TickTick, verify the phone receives those
> notifications.** This is the one place where the honest answer is that you silently
> stop seeing things.

**Keep running, explicitly:** Obsidian (LiveSync + agent door), Tailscale.app,
**1Password.app** — it being unlocked is what makes `op read` and the SSH agent work here,
so do not extend the browser-quitting logic to it. **WalkingPad is infrastructure wearing
an `.app` bundle** (KeepAlive daemon feeding argo, 20 MB) — do not sweep it into an
app-pruning pass. The entire IU/work stack (`com.iu.prometheus-*`, the four work
containers) is untouched.

### L3.6 — WP13: physical network hygiene

WP13's headless half is **done** (2026-07-31): `RouteAll` is now `false` and the
serve conf names its two container-backed rows. The `idss-mysql` row was withdrawn,
not deferred — it is an IU work container. Everything below is what is left, and
none of it can be done after the screen comes off.

| Item | Action |
|-|-|
| en0 negotiating `100baseTX` on a 1 Gb/s NIC | Swap the cable. Error counters are clean (0 Ierrs/Oerrs/Coll over 48.2 M packets), so this is a stable negotiation to 100, not a dirty link. Verify `ifconfig en0 \| grep media` → `1000baseT`. |
| No DHCP reservation | Reserve `5c:e9:1e:ec:5a:6e → 192.168.1.100` on the Fritz!Box. Prefer a reservation over `networksetup -setmanual` — the router stays the authority for gateway/DNS. |
| Wi-Fi Private Address rotating | `0a:31:ca:27:7c:6d` is locally-administered. Turn off Private Wi-Fi Address for this SSID. **No CLI exists** — System Settings → Wi-Fi. **Keep Wi-Fi enabled:** it is the only failover if the wired path dies, and with the screen gone that would be total loss of access. |

This one is **pre-detach only** — it cannot be done headlessly at all.

### L3.6b — WP10 remainder: two holds needing your call

Disk went 275 Gi → 370 Gi free in the agent run (docker prune + fstrim took
`~/.colima` 78 G → 29 G; caches, cargo target, stale node_modules, installers and
wallpaper assets accounted for the rest), then settled at **368 Gi** after the WP12
brew upgrades (`brew cleanup -s --prune=all` already run). The WP10 acceptance bar
is 380 Gi, so it is **~12 Gi short**, and both remaining items were deliberately
left for you:

| Hold | Size | Why it stopped |
|-|-|-|
| JetBrains pre-2026 state, 34 dirs | 12.04 GiB | Config/caches for versions no longer installed. Enumerated, nothing deleted. |
| Home archive → NAS | 8.6 GiB | `~/Movies` 3.5 G, `~/SY` 2.2 G (confirmed not a git repo), `~/Downloads/mindsera_memos` 1.8 G, `~/transactional-outbox-nestjs` 1.1 G (**is** a git repo, working tree clean), `~/Pictures/ImageGen` 22 M. The NAS mount needs a credential. |

Either one alone clears the bar. Two cautions carried forward from the plan and both
confirmed on the machine: the obvious JetBrains glob `ls -d *20{22,23,24,25}*` **misses**
`PhpStorm2024.3`, `JetBrainsClient223.8617.44` and the legacy lowercase `Phpstorm/` and
`Webstorm/`; and WebStorm has **two** current versions (2026.1 and 2026.2), so one dir
per product does not hold. For the NAS, do not make it a permanent mount — an SMB mount
that dies on network loss hangs every process holding a handle on it, on a machine whose
whole point is surviving network cuts. And verify restic coverage before treating it as
backup: `homelab/restic-excludes.txt` globally excludes `**/node_modules/**`,
`**/target/**`, `**/dist/**`, `**/build/**`, `**/.cache/**`.

### L3.7 — WP16: UPS

Any USB HID Power Device–class UPS (APC Back-UPS, CyberPower, Eaton) — macOS picks it up
with no driver. **Sequence matters:** attach → confirm it appears in `pmset -g ps` /
`pmset -g ups` → *then* set halt thresholds. `haltlevel`/`haltafter`/`haltremain` do not
appear in `pmset -g cap` today and only become settable once the hardware exists.

```bash
sudo pmset -a haltlevel 20 haltafter 5 haltremain 10
```

Honest framing: a UPS converts most outages into non-events and long outages into a
*graceful* shutdown — which protects APFS and colima's VM image, and is precisely what
prevents the dirty-start failure WP7 works around. It does **not** solve unattended
restart; a graceful shutdown lands at the same auth screen. Damage control plus a
prerequisite, not the answer.

### L3.8 — WP17: detach

Gated on WP2, WP4, WP6, WP7, WP8 and WP14 acceptance tests all passing.

Pull the monitor, leave the HDMI dummy plug in, power-cycle at the wall once as final
proof. Then confirm from the MacBook within 10 minutes, with no human intervention:

```bash
ssh mini                                  # reachable
ssh mini 'claude agents --json'           # agents listed, max billing
ssh mini 'docker ps'                      # nine containers
ssh mini '/usr/local/bin/obsidian version'
open vnc://mini                           # desktop (needs auto-login, i.e. WP6)
curl -sI https://argo.mini.jkrumm.com     # dev door answers
```

---

## Open questions the owner still has to answer

| Question | Recommendation from the plan |
|-|-|
| The `:8443` Funnel is public and unauthenticated | **Inspect, then most likely delete.** Only the static frontend is funneled — `dashboard-api` is bound `127.0.0.1:2720` and is in no serve row, so an external browser cannot reach the data layer. What is public is the built JS bundle. Check what it embeds (endpoints, tokens, internal hostnames) before deciding; the hostname is permanently discoverable in Certificate Transparency logs, so obscurity is not a control. |
| GitHub PAT `op://mini/github/token` has no expiry and `Contents: read+write` on **all** repos | **Reduce scope** rather than adding an expiry. An expiry reintroduces exactly the silent-rot failure the cache-backed helper was built to replace; scope reduction has no such failure mode. |
| Should durable agents auto-restart after a reboot? | **Decide explicitly.** After WP4 a launchd-supervised `claude --bg` no longer needs the GUI session, which makes "yes" cheap. If the answer is "no", nothing to build. |
| Time Machine — no destination configured at all | **Configure it, after WP10.** Adding a network destination to a machine already writing heavily would add substantial I/O; fix the write pathology first. |
| Should a Tauri desktop app be built on a permanently headless mini? | Probably not. If only `gateway/` (220 K) belongs here, WP10c stops being a recurring 6.4 GB. |
| JetBrains pre-2026 state (~12 GB) | Enumerated by the agent run, deleted nothing. Needs your call. |
| The four IU work containers | Outside the "leave the work stack alone" boundary only if you want it to be. ~1.5 GB, and stopping them takes the Funnel endpoint down. `idss-mysql` may hold un-persisted state. Drive it through the owning repo's Makefile, never raw docker. |
