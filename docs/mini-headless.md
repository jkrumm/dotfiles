# Detaching the mini — headless readiness plan

Status: proposed, nothing executed. Audit date 2026-07-31.

Source: a 10-dimension read-only audit of `mini` (Mac14,12, M2 Pro, 32 GB, macOS
26.5.2, uptime 6d10h), 98 findings, 41 adversarially verified, 11 refuted. Plus a
targeted research pass on the FileVault / auto-login / keychain question, which
**overturned the audit's own working hypothesis** — see WP4.

Owner decisions already taken (2026-07-31), folded in throughout:

| Question | Answer |
|-|-|
| FileVault | Open to disabling if there is no big hassle and no data loss. Buying a UPS regardless. |
| Cleanup | Kill vendor updaters/daemons. **Do not uninstall apps** — stop them booting, keep them on disk; the mini may be a headful workstation again someday. Clawbar gets stopped, owner fixes it in parallel. IU/work stack untouched. |
| Break-glass | HDMI dummy plug + Screen Sharing. |
| This turn | Plan only, execute nothing. |

---

## 1. Verdict

The screen cannot come off today, and bloat is not the reason. Four independent
layers stop this machine from coming back after a power cut: `pmset autorestart 0`
means it never powers on; FileVault with no auto-login halts it at the pre-boot
unlock screen; **15 of 20 always-on services are bootstrapped into `gui/501`** and
do not exist without a GUI login; and the Tailscale node key expires **2026-10-10**,
after which recovery requires a browser on the mini — a monitor, physically
reattached. The machine is also thrashing right now: 12.6 GB of 13.3 GB swap used,
15.3 GB of RAM held by the compressor, two full cores burned by a spin-looping
Clawbar and a leaked `python -` heredoc. That already cost real work — herdr was
SIGKILLed once (`launchctl` still reports `last terminating signal = Killed: 9`),
and a herdr crash restores the layout but loses every process in it.

The chosen break-glass path is coupled to the FileVault decision in a way worth
naming up front: **Screen Sharing needs an already-logged-in GUI session.** At the
FileVault pre-boot prompt it is unavailable. So "HDMI dummy plug + Screen Sharing"
is only a real recovery path once auto-login exists — which requires FileVault off.
Keeping FileVault means the break-glass path is a physical monitor, not VNC.

Everything else here is cleanup. Those four are the gate.

---

## 2. Blockers

| # | Blocker | Decision |
|-|-|-|
| B1 | Tailscale node key expires 2026-10-10 (71 days). `homelab` and `vps` have expiry disabled; the mini does not. | None — just do it. Console-only; `op://Private/Tailscale` is refused by the mini's cache by design. |
| B2 | `pmset autorestart 0` — mains returns, machine stays off. | None. Needs sudo from the MacBook. |
| B3 | FileVault ON + no auto-login. Apple documents the two as mutually exclusive. | **Recommend: disable.** See §3 for why the hassle and data-loss concern does not apply on Apple Silicon. |
| B4 | **Auto-login does not unlock the login keychain.** Claude Code Max auth lives there with no file fallback. | Mint a long-lived token into the secrets cache. **Mandatory, not optional** — see WP4. |
| B5 | sideclaw's SQLite job DB is an **unlinked file in `/tmp`**. So are sideclaw's and litellm's logs. | None — fix it. |
| B6 | 15 of 20 services die with the GUI session. Only caddy, dnsmasq, the colima docker-socket daemon, sshd and Tailscale are true system daemons. | Accept + auto-login, or convert. Recommend accept (see §7). |
| B7 | Memory 2× oversubscribed; herdr already died to it once. | Confirm Chrome and Helium get quit and stay quit. |
| B8 | All 8 live Claude agents are `"kind": "interactive"`, all children of the single herdr server PID. One `kill -9` — which memory pressure has already delivered once — destroys all of them, including 20 hours of work. | None. `rd bg` already exists; move the long-lived work to it. |

**Not blockers, contrary to the first pass.** `op read` and GitLab SSH do *not*
hang on this machine — both measured working (`op read` returns a real error in
~5 s; `git ls-remote git@gitlab.com` rc=0 in 2 s). They work because 1Password.app
is unlocked in the live console session, which makes them **consequences of B3**,
not independent defects. Do not "fix" them by stripping `SSH_AUTH_SOCK`.

---

## 3. The FileVault question, answered

You asked whether disabling it is a hassle or risks data loss. On Apple Silicon,
no — and the reason is architectural, not a workaround.

The internal SSD is **always** encrypted, FileVault or not. The volume encryption
key is wrapped by the Secure Enclave. FileVault only controls *what* wraps it.
Apple's current Platform Security guide states it verbatim:

> With FileVault turned off, the volume encryption key is protected only by the
> hardware UID in the Secure Enclave.

So `fdesetup disable` is a key-rewrapping operation in the Secure Enclave, not a
bulk decryption pass over 672 GB. It is effectively instantaneous. This machine's
own `diskutil apfs list` already shows the shape — `FileVault: Yes (Unlocked)`
alongside `Encrypted: No` at the container level, because the encryption is
hardware and always on.

What survives with FileVault off, on Apple Silicon:

| Attack with physical possession | Gated? |
|-|-|
| Offline NAND extraction | Yes — ciphertext only. The UID is fused in silicon, never exposed to software. |
| recoveryOS | Yes — requires a user password. |
| Share Disk / Target Disk Mode | Yes — requires an admin password. |
| DFU restore | No — but it **wipes** the disk. Thief gets a clean Mac, not your data. |
| **Pressing the power button** | **No.** |

That last row is the entire delta. FileVault here buys exactly one thing: stopping
someone who has the machine from pressing power and getting a logged-in desktop.

**The blast radius of that one thing, enumerated honestly.** A logged-in desktop
holds `~/.config/sops/age/keys.txt` (189 B, 0600), which decrypts all 136 cached
refs — including the work `headless.iu.refs` exceptions and read-only prod DB
passwords. Plus a Cloudflare API token inlined in cleartext **twice** in
`/opt/homebrew/etc/Caddyfile.d/tailnet.caddy`, `ARGO_TOKEN` and `KSWP_ARGO_TOKEN`
in cleartext in two LaunchAgent plists, and 27 GB of source across `~/SourceRoot`
and `~/IuRoot`.

`dotfiles-private/docs/security-review.md:314` already states encryption-at-rest is
"caveated by FileVault-off, PRD §15", so no document is invalidated by this.

**Recommendation: disable it, and buy the UPS anyway.** The UPS is not an
alternative — a graceful shutdown lands at the same auth screen. It protects APFS
and the Lima VM image from dirty shutdown, which is what prevents the colima
cold-start failure WP7 otherwise has to work around. Damage control plus a
prerequisite, not the answer.

**The one caveat that changes the plan.** Research confirms with high confidence
that **automatic login does not unlock the login keychain** — the password is never
typed, so it is never supplied to the keychain subsystem. Any service needing a
keychain credential after an unattended reboot stalls on a GUI dialog nobody will
answer. The audit had this as an unresolved "working hypothesis is that it does";
it does not. The documented workaround — setting an empty keychain password — makes
every stored secret readable by any process on the machine, which is a worse trade
than what FileVault-off exposes. So WP4 is promoted from nice-to-have to mandatory,
and it must land **before** WP6.

---

## 3b. macOS 26 adds remote FileVault unlock over SSH — WP6 is no longer forced

Added 2026-07-31, after §3 was written. **§3's premise — that break-glass with
FileVault on means a physical monitor — is out of date.** macOS 26 Tahoe added
pre-boot SSH unlock, and this machine already meets every prerequisite.

Verified against **this machine's own man page**, not a blog post:

```
$ man 7 apple_ssh_and_filevault
HISTORY
     The capability to unlock the data volume over SSH appeared in macOS 26
     Tahoe.
```

| Prerequisite | This machine |
|-|-|
| Apple Silicon | Mac14,12 (M2 Pro) ✓ |
| macOS 26+ | 26.5.2 (25F84) ✓ |
| FileVault enabled | On ✓ |
| Remote Login enabled | sshd listening v4+v6 ✓ |
| Wired ethernet | en0, 192.168.1.100 ✓ |

**What it gives you.** After a reboot the machine sits at pre-boot with a
minimal sshd served from the sealed System volume. You ssh in, it accepts a
**password** for any FileVault-enabled account, unlocks the Data volume, drops
the connection, and boot continues. Password only — `authorized_keys` lives on
the volume that is still encrypted.

**What it does NOT give you, and this is the part every summary omits.** Unlock
is not login. macOS continues to the **login window**, not to a session. The
15-of-20 services in `gui/501` — herdr, sideclaw, litellm, the hermes gateway,
the colima brew service, devhost-health, collie, Obsidian — are still absent.
Only system-domain daemons come up: sshd, tailscaled, caddy, dnsmasq, the colima
docker-socket daemon. So this replaces B3, not B6.

**Three constraints measured here, all binding:**

1. **Tailscale does not exist pre-boot.** Its state is on the Data volume, so
   there is no MagicDNS, no `ssh mini`, no tailnet IP. The unlock must be
   delivered to the machine's **LAN address**, over the LAN. That is the whole
   ballgame for a remote recovery story.
2. **homelab is NOT a jump host into that LAN, contrary to what this document
   assumed.** Measured: the mini is `192.168.1.100` behind gateway
   `192.168.1.1`; homelab is `192.168.178.129`. Neither can reach the other's
   LAN address — they meet only over Tailscale (direct IPv6, 7 ms, so the
   tailnet path is healthy). **They are on different networks.** The WP13
   rationale that said "a machine on the same LAN, one L2 hop away" was simply
   wrong. Today, pre-boot unlock therefore works only from a device physically
   on the mini's LAN.
3. **Screen Sharing is probably available at the login window, and the plan says
   otherwise.** `com.apple.screensharing` is a **system-domain** job whose
   `state = not running` is socket-activation idle — the same tell as sshd, not
   an outage. That contradicts §1's "Screen Sharing needs an already-logged-in
   GUI session". **Unverified**: settling it is exactly what L3.2's logout test
   is for. If it holds, the full remote path is ssh-unlock → VNC to the login
   window → log in → all 20 services, with no monitor and no FileVault change.

**`fdesetup authrestart` is the other half, and it is not a substitute.**
`fdesetup supportsauthrestart` → `true` here, and the local man page documents
`-delayminutes -1` as "never auto-restart; the auth restart occurs whenever the
user next restarts" — i.e. arm now, bypass the prompt on the next reboot. It
covers a **planned** reboot completely and can be scripted (`-inputplist`). It
does **not** cover this move or a power cut: the extra unlock key is held in
memory (and on supported systems the SMC), it is single-use on Apple Silicon,
and a power-off plus transport destroys it.

**Revised decision — WP6 becomes a genuine choice rather than a forced move:**

| | Keep FileVault + SSH unlock | WP6 as planned (FileVault off + auto-login) |
|-|-|-|
| After a power cut | Two remote steps: ssh-unlock, then log in | Zero steps — boots to a live session |
| Reachable from | **Only the mini's own LAN** | Anywhere (Tailscale is up as soon as it boots) |
| Physical possession | Power button gets an attacker a lock screen | Power button gets an attacker a logged-in desktop, and `~/.config/sops/age/keys.txt` |
| WP4 (Max auth off keychain) | Still worth doing, no longer a gate | Mandatory before the switch |

**Decision, taken 2026-07-31 after one reversal: disable FileVault (WP6).** The
keep-FileVault column was chosen first and then rejected within the hour, once
the second row of that table was followed through. The new LAN has no homelab
and no other always-on tailnet node, so "reachable only from the mini's own LAN"
means *nobody* can reach it while the owner is away.

The deciding argument is that **unlock is not login**, so no amount of remote
access makes the keep-FileVault path automatic. Even with a jump node on that
LAN it is two manual steps after every power cut, forever. Only auto-login
removes the human from the loop, and it happens to delete the need for the jump
node and the availability case for the UPS at the same time.

Two corrections this reversal forces on the rest of the plan:

- **WP4 goes back to mandatory, and back to being a hard gate before WP6** —
  §3's original ordering rule, restored. Auto-login does not unlock the login
  keychain.
- **`fdesetup authrestart` is not a fallback for any of this.** Single-use on
  Apple Silicon, and a power-off plus transport destroys the stored key.

What is *not* thrown away: the §3b finding stands on its own merits and the
`apple_ssh_and_filevault` path remains the fallback if FileVault is ever turned
back on. L3.2's logout test is still worth doing before the move for exactly
that reason — it costs minutes and it is the only thing that tells you whether
Screen Sharing answers at the login window.

**Open question this raised, worth testing before buying a UPS.** `pmset
autorestart` means "restart after power *failure*"; a UPS-triggered graceful
shutdown is a deliberate off, and Macs generally stay off when mains returns
after one. If that holds here, a UPS would convert "long outage → machine
reboots itself" into "long outage → machine stays off" — making availability
worse for exactly the case it was bought for, while still earning its keep on
APFS and Lima-image integrity. **Unverified on this hardware.** Test with
`pmset -g ps` and a deliberate `shutdown -h` + power-cycle before committing to
halt thresholds (WP16).

---

## 4. Work packages

**Ordering rule.** WP1 and WP2 come first and nothing else starts until WP2 passes.
WP1 removes a countdown that ends in physical reattachment. WP2 proves break-glass
*while a screen is still attached*, so every later package has a proven way back.
WP4 precedes WP6 because of the keychain finding above. WP17 (detach) is gated on
WP2, WP4, WP6, WP7, WP8 and WP14 all passing.

**Sudo on the mini.** The root password is deliberately MacBook-only
(`op://Private/mac-mini-server/password`, biometric, refused unconditionally by the
mini's cache). Every sudo step runs from the MacBook:

```bash
ROOT_PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm) && \
  ssh mini "echo '$ROOT_PW' | sudo -S <cmd>"
```

`sudo -S` reads stdin, so no `ssh -t` — which matters, because a `!`-prefixed
Claude Code command gets no TTY.

---

### WP1 — Disable Tailscale key expiry

**Where:** MacBook / Tailscale admin console. **Goal:** remove the one failure that
cannot be recovered without a monitor.

Console → Machines → ⋯ → Disable key expiry. **Six devices, not two** — the
original table here listed only the mini and the phone, and understated the
wall-clock urgency. Re-measured 2026-07-31, still all outstanding:

| Device | Days left | Note |
|-|-|-|
| `localhost` (phone) | **5** | collie access dies with it |
| `IUGMXK9P6DY1XC` | **5** | work machine |
| `TB330FU` (tablet) | 19 | holds the `tag:tablet` dev-door grant |
| **`mini`** | **70** | **recovery needs a browser ON the mini — a monitor, physically reattached** |
| `apple-tv` | 69 | optional |
| `TV` | 108 | optional |

The mini stays first because it is the only one that cannot be recovered
remotely, but the two 5-day entries are the ones about to lapse. `homelab`, `vps`
and every `funnel-ingress-node` already read `never`.

**Acceptance:**
```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["KeyExpiry"])'   # expect: None
```

**Rollback:** re-enable in the console. Revocation stays one click regardless.

---

### WP2 — Prove break-glass, screen still attached

**Where:** MacBook + mini. **Goal:** every later package gets a proven way back.

1. From the MacBook: `make remote-dev-doctor` (currently 10/10).
2. Confirm Screen Sharing over the tailnet (`vnc://mini`). Port 5900 is listening
   v4+v6 and `screensharingd` is socket-activated, so the door exists. **State its
   limit in the runbook:** it needs an already-logged-in GUI session and is useless
   at a FileVault pre-boot screen.
3. Fit the HDMI dummy plug (~5 EUR, passive EDID emulator). A Dell U4919DW has been
   attached continuously since Jul 24 — the no-EDID case has **never** been
   exercised on this box, and Obsidian is Electron. Community consensus is that
   macOS does not synthesise a usable framebuffer without EDID; this is the one
   claim in the plan that research could not verify against a primary source, so
   treat the plug as cheap insurance and verify empirically.
4. Enable Tailscale "Run unattended" in the menu bar (macsys build only).
5. **Test it correctly:** log OUT and leave the mini at the login window — do
   **not** reboot. With FileVault on there is no "booted but not logged in" state
   reachable by rebooting, so a reboot test silently measures the logged-in case and
   returns a false pass. Then from the MacBook: `tailscale ping mini`, `ssh mini`.
6. `sudo sfltool dumpbtm > /tmp/btm.txt` — it returns zero bytes without root, so
   SMAppService background items are the single enumeration gap in this entire
   audit. Diff against the legacy login-item list (`Jiggler, Raycast, Clawbar`).
7. Confirm the physical recovery kit: spare monitor, keyboard, cable, reachable in
   minutes.

**Acceptance:** `tailscale ping mini` + `ssh mini` both succeed while the mini sits
at the login window. `/tmp/btm.txt` is non-empty.

**Human:** at the mini for 3, 4, 6; at the MacBook for 1, 2, 5.

---

### WP3 — Return two cores and the RAM, now

**Where:** mini. Fully reversible, touches no launchd job, no config, no secret.

```bash
kill -9 87462                                        # leaked python@3.14 heredoc
osascript -e 'quit app "Clawbar"'                    # owner is fixing it separately
osascript -e 'quit app "Google Chrome"' -e 'quit app "Helium"'
pgrep -lf '^/opt/homebrew/bin/herdr server'          # VERIFY 9 PIDs, none is 89992
pkill -f '^/opt/homebrew/bin/herdr server'
```

Load-bearing notes:

- **`kill -9`, not `kill`.** PID 87462 is stuck inside CPython's C-level
  `sre_ucs2_match` under `re.sub()` — catastrophic backtracking, 919 CPU-minutes
  for a 0-byte output file whose stdin script is already unlinked. It never returns
  to the eval loop, so SIGTERM is ignored indefinitely.
- **Clawbar is a login item, not a brew service.** `brew services stop clawbar` is a
  no-op. Quitting alone means it returns at next login; the durable half is the
  login item in WP8. Its 70 MB analytics cache is re-encoded whole every ~5 s at
  96–100% CPU, RSS climbing 597→659 MB across sampling. Drop the "1.24 TB/day to
  the NVMe" framing from the raw audit — the *whole machine* wrote 1692 GB in
  6.4 days, so that figure is impossible. The defensible claim is one full core and
  659 MB burned by a menu-bar app on a screenless host.
- **The anchored herdr pattern is the safety.** The live server is PID 89992 with
  argv `/opt/homebrew/opt/herdr/bin/herdr server` — the path the brew plist pins —
  so `^/opt/homebrew/bin/herdr server` cannot match it. All 7 live `claude`
  processes are grandchildren of 89992. Quitting cmux drops a herdr *client* only;
  the server and its agents survive.
- **Chrome is unresponsive to AppleEvents** (`-1712` timeout observed). Have a
  fallback ready.
- **Do not quote summed RSS as recoverable RAM** — 122 browser processes
  double-count shared framework pages. Measure `vm_stat` before and after.

**Acceptance:** `vm.swapusage` used drops well below 11.5 GB; no process sustained
above ~20% CPU; `herdr session list` still reports `default`; `claude agents` still
lists the running agents.

---

### WP4 — Take Claude Max auth off the login keychain

**Where:** mini, human present for one interactive session. **Mandatory before
WP6**, per §3. Highest-leverage package in the plan: it dissolves the
`rd bg`-through-a-herdr-pane workaround, makes `ssh mini 'claude --bg …'` correct,
unblocks sideclaw-as-daemon, and removes the one thing auto-login demonstrably
cannot provide.

1. `claude setup-token` from a present-human session.
2. **Confirm the env var name against the current CLI** before wiring it. It must be
   `CLAUDE_CODE_OAUTH_TOKEN`, never `ANTHROPIC_API_KEY` — exporting the latter flips
   billing to API credits, which is the exact failure this fixes.
3. Add the ref to `dotfiles-private/headless.refs` (e.g.
   `op://mini/claude/oauth-token`) with a T-classification note, and to
   `docs/security-review.md` as a standing Max credential readable by anything that
   can call `secrets-run`.
4. From the MacBook: `cd ~/SourceRoot/dotfiles-private && git pull` — the seed reads
   the **local** `headless.refs`, so a ref added on the mini and left unpushed is
   silently omitted. Then `make secrets-seed` from `~/SourceRoot/dotfiles`.
5. Export it via `secrets-run` in whatever launches `claude`.
6. **In the same change**, add a `claude auth status` assertion to
   `scripts/devhost-health-check.sh` — one `jq` over its JSON. Not optional: an
   expired token reproduces today's silent-API-billing failure exactly.

**Files:** `dotfiles-private/headless.refs`, `dotfiles-private/docs/security-review.md`,
`dotfiles/scripts/devhost-health-check.sh`, `dotfiles/scripts/remote-dev.sh` (drop
the herdr-pane indirection in `cmd_bg` once proven).

**Acceptance:** from the MacBook, `ssh mini 'claude --bg "echo ok"'` produces a
daemon reporting `loggedIn: true`, `subscriptionType: max` — not `Not logged in`.

**Rollback:** revoke the token; the login-keychain path still works while a GUI
session exists.

---

### WP5 — Power-on layer

**Where:** MacBook (sudo over ssh).

```bash
sudo pmset -a autorestart 1 && sudo pmset -a autorestartatconnect 1
sudo pmset -a powernap 0
```

Both keys are listed settable in `pmset -g cap` on this Mac14,12 / macOS 26.5.2 —
verified, not assumed. `autorestartatconnect` is laptop-oriented and redundant on a
battery-less mini, but harmless. `powernap` only acts during sleep and this machine
has `sleep 0`, so it is dead configuration surface.

Leave alone: `womp 1`, `tcpkeepalive 1` (0 disables wake-for-network),
`ttyskeepawake 1` (herdr/mosh sessions are ttys), `sleep 0`. One dependency worth
remembering: `powerd`'s `PreventUserIdleSystemSleep` assertion is named "Prevent
sleep while display is on" and **disappears when the monitor is detached**, after
which `sleep 0` is the only thing keeping the machine awake. Do not relax it.

**Acceptance:** `system_profiler SPPowerDataType | grep 'Power Loss'` →
`Automatic Restart on Power Loss: Yes`. Check this, not just `pmset -g custom`.

---

### WP6 — Disable FileVault, enable auto-login

**Where:** mini, human physically present. Gated on WP4 passing.

1. `sudo fdesetup disable` — requires an interactive volume-owner password prompt,
   so it cannot be scripted headlessly. `jkrumm` has a Secure Token and is a volume
   owner (verified), so this will succeed.
2. `sudo sysadminctl -autologin set -userName jkrumm`. Use the supported mechanism;
   do not hand-write `/etc/kcpassword`.
3. Reboot. Decisive test from the MacBook: start an `rd bg` agent and check
   `claude auth status` returns `loggedIn: true, subscriptionType: max`. This is
   what WP4 makes survivable — expect the login keychain itself to be **locked**.
4. Decide the three console-security settings explicitly rather than inheriting
   undeclared defaults: `askForPassword` (neither `com.apple.screensaver` nor its
   ByHost variant declares it today), Screen Sharing → "Allow access for → only
   these users → jkrumm", and clear the legacy
   `/Library/Preferences/com.apple.VNCSettings.txt` (32 bytes, dated Jun 11) —
   CLAUDE.md says the VNC password should be off.
5. Verify the ACL's `dst` for :5900 is not `tag:mac`-wide, with `tag:client` (two
   TVs + tablet) one mis-scoped grant away.

**Acceptance:** power-cycle at the wall. Machine comes back; `ssh mini` works;
`claude agents` lists a healthy agent on `max` billing; `herdr session list`
responds; `vnc://mini` shows a desktop.

**Rollback:** `sudo fdesetup enable` + `sudo sysadminctl -autologin delete`.
Re-enabling does run a real encryption pass and takes time — the asymmetry is
expected.

---

### WP7 — Boot-path correctness

**Where:** mini + dotfiles. **Goal:** the paths that have never actually executed at
boot do the right thing when they finally do. Last boot was Jul 24; several of these
were written after it.

| Item | Defect | Fix |
|-|-|-|
| colima | `KeepAlive => {SuccessfulExit => true}` — restarts on *clean* exit only. A failed `colima start -f` after a dirty shutdown is never retried, and nothing checks `docker info`. | Bare `KeepAlive => true`. **`{Crashed=true}` does not work** — `Crashed` means death by signal, not a non-zero exit. Pair with a bounded retry or a start wrapper: with `true`, a persistently dirty Lima image becomes a VM start attempt every 10 s forever. Pin the fix in `make setup` (brew regenerates the plist) and correct the false "RunAtLoad + KeepAlive so it's always-on" claim in `dotfiles/CLAUDE.md`. |
| caddy | `Caddyfile.d/tailnet.caddy` hardcodes `bind 100.87.73.3` in two site blocks. caddy is a system LaunchDaemon starting pre-login; the tailnet address is created by the Tailscale GUI app at login. Binding an unassigned address returns `[Errno 49]` and Caddy aborts the **whole** config — `.test` and `metabase.iu-aws.de` go with it. Include born Jul 29, last boot Jul 24: never exercised. | Bounded outage, not permanent — launchd retries a KeepAlive job on a 10 s throttle, so caddy self-heals ~10 s after the utun address appears. Fix anyway: a wait-for-address wrapper on the daemon. A *user* LaunchAgent regenerating the include would only fire at login, so it is the wrong shape. |
| Hermes gateway | plist PATH embeds a dead fnm multishell dir keyed to PID 95674 and a `$TMPDIR/cmux-cli-shims/…` path wiped at boot. Clear evidence the plist was generated by dumping a GUI cmux session's environment. | Rewrite to stable absolute paths only, matching the sideclaw/litellm/collie shape. The venv bin is first so the gateway probably still starts — but anything it shells out to vanishes after the first reboot and will look like a Hermes bug. |
| Obsidian | not a login item; started by hand Jul 27, 2.5 days after boot. Hard agent dependency for `/brain` and Hermes's `obsidian` skill. | LaunchAgent with `ProgramArguments = ["/usr/bin/open", "-a", "Obsidian"]`, `RunAtLoad` true, **no KeepAlive** — a KeepAlive agent exec'ing the binary directly bypasses LaunchServices and respawns the app the instant a human quits it. Template + `make obsidian-autostart`, gated on the `cache` backend marker, same gate `collie-setup` uses. |
| Dead plists | `ai.hermes.gateway.plist.pre-cache.bak`, `.homebrew.mxcl.caddy.plist.disabled-20260727`, `com.macromates.auth_server` (root privileged helper for a deleted TextMate), `com.microsoft.SyncReporter` (empty `ProgramArguments`), two empty-dict Google Keystone stubs | Delete. The `.bak`-class files are exactly what a `for f in ~/Library/LaunchAgents/*; do launchctl load` recovery would pick up, creating a second caddy fighting the root one for :443. TextMate's helper is dead root attack surface. |

**Do not "fix":** `brew services list` showing `caddy none` and `dnsmasq none` is a
**reporting artifact** — `brew services` was invoked without sudo and can only
enumerate `gui/501`, while both live in `system`. Its own output gives the tell: the
`User` column says `root` while `File` is blank. `launchctl print system/…` shows
both `state = running` (PIDs 91368 and 549, dnsmasq since boot). Starting them with
`brew services start` creates a duplicate user-domain job fighting for :443. Add a
line to `CLAUDE.md` so this is not re-diagnosed. `batt none` is also correct — the
mini has no battery.

**Acceptance:** after a deliberate reboot — `docker ps` works unattended,
`curl -sk https://rb.test` resolves through caddy, `/usr/local/bin/obsidian version`
exits 0, `launchctl print gui/501/ai.hermes.gateway` shows a healthy PATH.

---

### WP8 — Stop things booting (no uninstalls)

**Where:** mini, screen attached or Screen Sharing. **Goal:** everything that needs a
dialog answered gets answered while a dialog can be answered.

Per your decision: **nothing is uninstalled.** Apps stay on disk so the mini can be
a headful workstation again. This package only stops things *starting*. That also
means **no Brewfile edits** — the manifest keeps describing the machine truthfully,
and `make brew-check` keeps passing.

**Vendor updaters and daemons — bootout + disable.** These are the pure background
tax you approved removing:

| Item | Location |
|-|-|
| Google Keystone ×3 (`GoogleUpdater.wake`, `keystone.agent`, `keystone.xpcservice`) | `~/Library/LaunchAgents` |
| Microsoft AutoUpdate helper, OneDrive ×2 updaters, Office licensing, Teams updater | `/Library/LaunchDaemons` |
| Microsoft SyncReporter (empty `ProgramArguments`) | `/Library/LaunchAgents` |
| Logitech G HUB agent + updater daemon | `/Library/LaunchAgents`, `/Library/LaunchDaemons` |
| Zoom root daemon, Amazon acvc helper | `/Library/LaunchDaemons` |
| TextMate `auth_server` (app already deleted — dead root attack surface) | `/Library/LaunchDaemons` |
| Riot client check-installs, JetBrains Toolbox | `~/Library/LaunchAgents` |

Use `launchctl bootout` plus moving the plist aside (not deleting — reversible, and
the app can re-register if you ever go headful). System-domain items need sudo.

**Login items** (`Jiggler, Raycast, Clawbar`): remove all three. Jiggler is not even
running and its purpose is already served by `pmset sleep 0`. Expect
`osascript … delete login item "Clawbar"` to fail with "Can't get login item" — a
modern app that self-registers at first launch uses SMAppService, which never
appears in the legacy list. That is a System Settings → General → Login Items &
Extensions action. Also remove Spotify's `StartupHelper.app`, present in
`backgrounditems.btm`.

**System extensions — SIP is ENABLED**, so `systemextensionsctl uninstall` will
refuse. Do not disable SIP for this.

1. **RadioSilence** (`com.radiosilenceapp.client.NetworkExtension`, PID 567,
   `[activated enabled]`, app already deleted from /Applications, LaunchAgent
   respawn-looping on `EX_CONFIG (78)` — one of only two non-zero exit statuses on
   the box). Stated accurately: an orphaned, unconfigurable content-filter extension
   is loaded in the network path — not "filtering all traffic" (0.0% CPU, 16 MB, no
   configuration proven). Try `systemextensionsctl gc` first — garbage-collects
   orphaned extensions, not SIP-gated, exactly this case. Otherwise System Settings
   → General → Login Items & Extensions → Network Extensions. Then bootout and move
   aside `/Library/LaunchAgents/com.radiosilenceapp.agent.plist`. **This is the
   prime suspect for any future unexplained network failure** on a host where
   Tailscale, the Funnel, the caddy dev doors and headless git push all traverse
   the stack.
2. **Karabiner-Elements and Logitech G HUB DriverKit extensions** (3 total). Since
   the apps stay installed, toggle the extensions **off** in System Settings →
   General → Login Items & Extensions → Driver Extensions rather than running the
   vendor uninstallers. Keep the tracked `config/karabiner/karabiner.json` — the
   Caps-Lock→Hyper remap only ever applied to a keyboard attached to *this* Mac;
   over `dev`/`desk` the keys are handled on the MacBook.

**Quit and de-login-item, keep installed:** Microsoft Teams (1.0 GB / 15 procs —
argo reads Teams server-side via M365, not the desktop app), Spotify (0.85 GB),
Claude.app (0.53 GB — agents use the CLI at `~/.local/bin/claude`), Raycast
(0.15 GB — the battery-limiter Script Commands are MacBook-only and self-gate on an
internal battery), TickTick (0.09 GB — Hermes and argo use the cloud API; a grep of
`hermes-agent` for `osascript|open -a` returned zero hits), WhatsApp, MacWhisper
(0.12 GB, also carrying a stale `iu-mac-book…/v1` LocalAI provider from the retired
stack), cmux, Ghostty, DevUtils, Riot Client. Close the stray Calendar, Notes,
Preview, System Settings and Terminal windows.

Set a **static wallpaper** — `WallpaperAerialsExtension` (PID 703) has burned 5.2%
of a core for the entire 6-day uptime animating a desktop nobody is looking at.

**Keep running, explicitly:** Obsidian (LiveSync + agent door), Tailscale.app,
**1Password.app** — it being unlocked is what makes `op read` and the SSH agent work
here; do not extend the browser-quitting logic to it. **WalkingPad is infrastructure
wearing an `.app` bundle** (KeepAlive daemon feeding argo, 20 MB) — do not sweep it
into an app-pruning pass. The entire IU/work stack (`com.iu.prometheus-*`, the four
work containers) is untouched by your decision.

**Before quitting Teams / WhatsApp / TickTick, verify the phone receives those
notifications.** This is the one place where the honest answer is that you silently
stop seeing things.

**Acceptance:** `systemextensionsctl list` shows only Tailscale's extension.
`launchctl list | awk '$2 != 0 && $2 != "-"' | grep -v com.apple.` returns nothing.
`make brew-check` still passes (it does not today — see WP10).

---

### WP9 — Get logs and state out of `/tmp`

**Where:** mini + dotfiles. Small package, serious consequence. This is B5.

macOS's periodic cleanup deleted files in `/tmp` that long-running `KeepAlive`
agents still hold open. They are writing into **unlinked inodes** — output goes
nowhere recoverable, and the files never reappear because the fd was opened once at
spawn.

```
$ lsof -p 895 | grep tmp
bun 895 1u REG     0 161358906 /private/tmp/sideclaw.log     <- unlinked
bun 895 2u REG     0 161358907 /private/tmp/sideclaw.err     <- unlinked
bun 895 6u REG 12288 161361859 /private/tmp/sideclaw.db      <- unlinked
$ ls /tmp/sideclaw.db
ls: /tmp/sideclaw.db: No such file or directory
```

- **sideclaw's SQLite job database is a deleted file.** Its state exists only in
  PID 895's address space. The moment KeepAlive restarts it — which is exactly what
  happens after an OOM kill, and this machine OOM-kills things — every job record is
  gone.
- **sideclaw and litellm have no logs at all.** Post-mortem after a crash is
  impossible.
- Affected plists: `com.jkrumm.sideclaw`, `com.litellm.proxy`,
  `com.jkrumm.walkingpad`, `com.jkrumm.usage-tracker`, `com.jkrumm.brain-backup`,
  `com.jkrumm.secrets-freshness`, `com.iu.prometheus-*`. The interval-driven ones
  re-create their file each spawn so they survive; the two long-running `KeepAlive`
  ones do not.
- `devhost-health` and `linewatch-collector` already use `~/Library/Logs` correctly.
  Make that universal, and add rotation — `/tmp/walkingpad.err` is 35 MB growing
  ~1 line/sec with none.

**Move sideclaw's DB to a real path** (`~/Library/Application Support/sideclaw/`) in
the same change, and point `brain-backup`'s `StandardOutPath` at `~/Library/Logs/`
— `/tmp/brain-backup.log` is the only record of that agent's history.

---

### WP10 — Disk reclaim

**Where:** mini. 625 Gi / 926 Gi (70%) → roughly 57%. APFS and Time Machine
snapshots are ruled out — `tmutil listlocalsnapshots /` and
`diskutil apfs listSnapshots` both return empty, so there is no hidden purgeable
reserve. Per your decision, **apps are not uninstalled** — this package is caches,
build output and archive only.

**10a — Docker (best GB-per-risk on the machine).** `~/.colima` is 84 G because
`/dev/vdb1` (`/var/lib/docker`) is mounted `rw,relatime` **without `discard`**, while
root `vda1` has it — every deleted layer still occupies host blocks.

```bash
docker builder prune -f
docker image prune -a -f
docker container prune -f
colima ssh -- sudo fstrim -v /var/lib/docker
```

The `fstrim` is the step that actually shrinks the host file. **That sudo is the
Lima VM's passwordless sudo** (`colima ssh -- sudo -n true` succeeds), entirely
separate from the mini's own — it will not hang. Nine containers are running, so use
the non-`--all` container form. **`docker volume prune` is deliberately absent** —
`idss-mysql` and 11 active volumes hold real data. Docker reports 90.6 GB
reclaimable against only 76 GB used, so it double-counts layers shared between
images and build cache; **measure `du -sh ~/.colima` before and after rather than
promising a number.** To stop regrowth, schedule the fstrim weekly or add `discard`
to the vdb1 mount options. **Never use `colima delete` + recreate as the shrink
method** — `colima.yaml` says `disk: 60` while the live datadisk is 100 GiB, so a
recreate silently halves the ceiling and destroys every volume.

**10b — caches (~35 G).** Tool-native cleaners: `npm cache clean --force` (7.3 G),
`rm -rf ~/.bun/install/cache` (6.1 G), `uv cache clean` (3.3 G),
`brew cleanup -s --prune=all` (3.0 G), `go clean -modcache` (2.0 G), then
`~/Library/Caches/{PlexMediaServer,com.nabocorp.witsy.ShipIt,camoufox,ms-playwright,go-build,node-gyp}`
(~9.4 G). **Quit Chrome first** before touching `~/Library/Caches/Google` (2.0 G) —
66 live processes hold those files mmap'd. `~/Library/Application Support/Claude/vm_bundles`
(7.7 G) needs Claude.app quit first. Run all of this **when the herd is idle** — a
mid-flight `bun install` is corrupted by a cache wipe.

**10c — build output.** `rm -rf ~/SourceRoot/image-gen/app/src-tauri/target` (6.4 G,
confirmed gitignored, the only cargo target dir under either root). Worth asking
separately whether a Tauri **desktop** app should be built on a permanently headless
mini at all, or whether only `gateway/` (220 K) belongs here.

**10d — node_modules, selective (13.6 G total).**
`find ~/SourceRoot ~/IuRoot -maxdepth 2 -name node_modules -prune -mtime +90` first,
then delete only confirmed-stale trees. Scope strictly around repos with no running
container and no active agent — `rb`, `linewatch` and `sideclaw` back live
processes. Do this **before** 10b so reinstalls come from a warm cache.
`~/IuRoot/worktrees` (745 M) deserves an independent look.

**10e — JetBrains state, needs your call.** ~12 G of pre-2026 state under
`~/Library/Application Support/JetBrains`. Since apps stay installed this is
config/caches for versions no longer present. Enumerate with
`ls -d *20{22,23,24,25}*` and review before deleting — the obvious glob misses
`PhpStorm2024.3`, `JetBrainsClient223.8617.44`, and the legacy lowercase
`Phpstorm/` and `Webstorm/`. Note WebStorm has **two** current versions (2026.1 and
2026.2), so do not assume one dir per product.

**10f — home archive (~9 G, do last).** Safe-delete: `~/Downloads/*.dmg` — **six**
files totalling ~1.13 GB (Claude ×3, Paseo, Icon_Composer, Excalidraw) — plus the
paired `astryx-main.zip` and `hermes-agent-2026.5.16.zip` duplicates. Archive to
NAS: `~/Movies` (3.5 G), `~/SY` (2.2 G, confirmed **not** a git repo),
`mindsera_memos` (1.8 G), `~/transactional-outbox-nestjs` (1.1 G, **is** a git repo
— `git status` before moving). `~/Pictures/ImageGen` (22 M) belongs in the
B2/image-share stack via `/img`. **Leave `~/Obsidian` alone** — CLAUDE.md designates
it a cold backup to keep closed, and 13 M does not justify touching it. Also
`~/Library/Application Support/com.apple.wallpaper` + the matching container (2.3 G
of wallpaper assets on a machine with no monitor).

**NAS target:** `smb://samba.jkrumm.com/HDD` — live, 11 T free of 14 T, port 445
open over Tailscale at 100.85.139.104, and Finder's `FXConnectToLastURL` proves it
has been mounted before.

```bash
mkdir -p /tmp/nas && mount_smbfs //jkrumm@samba.jkrumm.com/HDD /tmp/nas
```

**Do not make this a permanent mount** — an SMB mount that dies on network loss
hangs every process holding a handle on it, on a machine whose whole point is
surviving network cuts. And **verify restic coverage before treating it as backup**:
`homelab/restic-excludes.txt` globally excludes `**/node_modules/**`, `**/target/**`,
`**/dist/**`, `**/build/**`, `**/.cache/**`.

**Acceptance:** `df -h /` shows ≥ 380 Gi free; `docker ps` still shows nine
containers; `~/SourceRoot/brain` git still clean.

---

### WP11 — Secrets and credential hardening

**Where:** mini + dotfiles. The migration is ~90% done — Hermes, the full IU
prometheus stack and image-gen all gate correctly on `secrets-run`, and the
MacBook→mini seed ritual needs **zero** manual steps on the mini. This is residue.

Immediate, zero-risk:

```bash
chmod 600 ~/SourceRoot/sideclaw/.env    # currently 0644, holds a 40-char GitHub PAT
```

Both siblings (`linewatch/.env`, `rb/.env.secrets`) are already 0600, so the 0644 is
plainly accidental.

| Item | Change |
|-|-|
| GitLab credential | The durable fix for 16 IuRoot repos: extend `~/.gitconfig-headless` with `[url "https://gitlab.com/"] insteadOf = git@gitlab.com:` plus a `[credential "https://gitlab.com"]` helper pointing at a GitLab twin of `scripts/git-credential-secrets-cache`. **The "add a PAT to `headless.refs` and reseed" step this row used to demand is wrong** — measured 2026-07-31: `op://vps/argo/GITLAB_TOKEN` is already in the cache, resolves headlessly, is active until 2027-05-16, and carries `read_user, read_api, read_repository`. A read-only fetch path could be wired today with no seed at all. What is genuinely missing is **`write_repository`** — so the deferral is "mint a write-scoped PAT", a one-line scope decision, not a cache-migration ritual. (`op://Private/feuer/gitlab-token` also resolves, under `OP_ACCOUNT=careerpartner`, but it is Feuer's service identity and is the wrong credential for personal git.) **Do not strip `SSH_AUTH_SOCK`** — GitLab SSH was measured working, and the export at `config/zsh/secrets.zsh:10` is deliberately preserved for Screen Sharing sessions (see the comment at :6-9). |
| `hooks/machine-role.ts:38-39` | Says "GitHub goes over HTTPS via the `gh` keyring token". Wrong since 2026-07-26 — it is `git-credential-secrets-cache` → `op://mini/github/token`. This string is the first thing every agent reads, and it reproduces the exact misdirection the helper's own comment block says cost a debugging cycle. Fix + `make hooks-test`. |
| `litellm/bin/start-litellm.sh:19-20`, `brain/brain-backup.sh:37-38` | Both read `security find-generic-password` with `|| echo ""` / `|| true` — an unreachable keychain yields an empty credential and the service starts broken with exit 0. **This becomes live the moment auto-login lands**, since the keychain will be locked. Move to `secrets-run read`, or at minimum drop the swallowing fallback. |
| `brain/brain-backup.sh` PATH | Missing `$HOME/.local/bin`, where `claude` actually lives — so every nightly run has silently used the literal fallback commit message `chore(brain): nightly vault sync`, never a generated one. One line. |
| `com.jkrumm.walkingpad.plist`, `com.jkrumm.usage-tracker.plist` | Plaintext bearer tokens (`KSWP_ARGO_TOKEN`, `ARGO_TOKEN`) in `EnvironmentVariables`, on the machine whose whole secrets design is "no plaintext secret on the mini". Move behind the cache with the `bash -c 'set -a; . .env; set +a; exec …'` shape the collie plist already uses — launchd has no `EnvironmentFile`. **Pin PATH explicitly**: `secrets-run` is not in launchd's default PATH. Rotate both tokens afterwards. |
| Ungated `op` call sites | `homelab/Makefile:16`, `homelab-private/Makefile:24`, `dotfiles/scripts/github-config.sh:150`, `king-smith-walkingpad-mac/scripts/install-launch-agent.sh:33`. Framed correctly: these work today and will **fail fast** once the GUI session is gone, not hang. Cheap insurance anyway — copy the `command -v secrets-run` shell-guard from `IuRoot/prometheus-scripts/analysis/Makefile:8`, and add `</dev/null` + `timeout 15` to the raw `op read` sites. |
| `scripts/secrets-rotate.sh` | Add a backend-marker guard mirroring `scripts/tailscale-acl-sync.sh:61-73`, and move the `op item delete`/`create` half to run from the MacBook over `ssh mini`. |
| Cloudflare token | Inlined in cleartext **twice** in the generated `tailnet.caddy`, duplicating the 0600 token file. The `{env.CF_TOKEN}` remediation is harder than it looks: caddy runs as a root LaunchDaemon whose environment comes from a Homebrew-generated plist rewritten on upgrade, and Caddy has no file-read placeholder. Weigh it — this swaps a 600-mode inline token for a brittle plist edit that silently reverts. |

**Sequencing trap:** any ref migration needs `make secrets-seed` from the MacBook
**before** the consumer is switched, or the service comes up credential-less.
`secrets-run` fails closed, so a half-done migration is loud. Already-running
processes keep their old env — after a reseed, `launchctl kickstart` the consumers
(hermes gateway, litellm, sideclaw, collie).

**Acceptance:** `make hooks-test` passes; `secrets-run read op://mini/github/token`
resolves; `git ls-remote` against a GitLab repo succeeds over HTTPS;
`make secrets-test` + `shellcheck` per the standing `secrets-run` guardrail.

---

### WP12 — Monitoring hardening

**Where:** dotfiles. `devhost-health-check.sh` is well-built — behavioural not
liveness-based (collie's 403 rebind assertion), fails loud, avoids outbound calls
that would page on a third-party wobble. Its history proves it works: 25 `✗` lines
caught the `health.mini.jkrumm.com` DNS drift. The problem is what it cannot see.

| Addition | Why |
|-|-|
| **Memory pressure / swap** | The single most likely thing to break this machine, and nothing checks it. It has already killed herdr once. The monitor reports `herdr up` right until the kill, then reports `herdr up` again after KeepAlive restarts an **empty layout** — the outage is invisible in both directions, and a herdr restart is silent loss of every process in every pane. |
| **Restart counts** (`runs`, `last terminating signal`) | A crash-looping KeepAlive service is currently indistinguishable from a healthy one. herdr's `runs = 2` and `-9` are sitting in `launchctl print` and nothing reads them. |
| **Liveness for six unmonitored always-on services** | sideclaw, litellm, hermes gateway, colima/`docker info`, caddy-as-a-process, dnsmasq. Note the asymmetry: `check_dev_vhosts` verifies caddy's DNS module and cert but never that caddy answers; and dnsmasq going down takes every `.test` name with it, unnoticed. |
| **Tailscale key expiry, days remaining** | `check_tailscale` asserts only `BackendState == "Running"` — it fires *after* the key expires and the machine is already unreachable. The cert check in the same file warns 21 days ahead; the asymmetry is backwards, since a cert failure is remotely recoverable and a key failure is not. **Must SKIP cleanly when `KeyExpiry` is `None`** so it stays correct after WP1. |
| **`claude auth status`** | Lands with WP4. An expired OAuth token reproduces the silent-API-billing failure. |
| **`/usr/local/bin/obsidian version` exit 0** | The CLI door is what `/brain` and Hermes use, not the process. |
| **Disk space** | 71% used, hourly SQLite snapshots, an unrotated 35 MB `/tmp/walkingpad.err`. |
| **Runaway reaper** | Gate on accumulated CPU time (`ps -o time`), **not** instantaneous `%CPU`, for PPID-1 processes with cwd under `~/SourceRoot`. **Exclude `claude --bg` daemons** — they are PPID 1 by design. |
| **Fold in secrets-freshness** | It runs as its own weekly agent (`Weekday=1 Hour=9`), so a cache going stale on a Tuesday is invisible until Monday. The 300 s devhost-health agent already exists; only the push target differs — the same argument already made and accepted for collie. Keep it as its own Kuma monitor (it does not fail with tailscaled/sshd/herdr, so it must not mark the dev host DOWN). Keep the 8-day threshold. |

**The unavoidable blind spot:** `com.jkrumm.devhost-health` is itself in `gui/501`,
so it cannot survive the no-GUI-login condition it exists to report on. If the
session dies, Kuma pages "missed heartbeat" — correct, but undiagnosable and
identical to the machine being off. Auto-login (WP6) is what makes this acceptable
rather than converting the agent to a system daemon.

Leave `check_git_push` as resolvability-only with no network call — the reasoning at
:174-181 is sound at a 300 s cadence with `maxretries 0`. The stronger claim lives
in `make remote-dev-doctor`, and that split has earned itself: on 2026-07-26 the
credential resolved fine while the deployed helper still pointed at Hermes's
read-only token, and only the dry-run caught it.

**Brew drift — done 2026-07-31, and it was five packages, not four.** The plan's
list omitted `gh`. All of it was version drift, not missing tools. Cleared in two
passes, deliberately split along the repo's own formula/cask line:

- `make brew-upgrade` took `docker gh glab llhttp simdjson` (all homebrew/core,
  one point release each). It converged the `caddy`/`mosh` pins first and then
  re-asserted all three silent-revert invariants afterwards — Cloudflare DNS
  module present, mosh-server still in the ALF allowlist, colima's supervised
  boot path intact. All passed.
- The casks are excluded from that target by design and were upgraded explicitly
  with the owner's consent: `warp` (one release, nothing running) and **`obsidian`
  1.1.9 → 1.13.4**. That second one replaces the app bundle `/brain` and Hermes
  reach the vault through, so it was done as quit → upgrade → relaunch → verify,
  with the vault git-clean first. Both symlinks (`/usr/local/bin/obsidian` and
  the cask's own `/opt/homebrew/bin/obsidian`) still resolve, the socket is live,
  and all four subcommands the brain contract uses (`search`, `backlinks`,
  `orphans`, `deadends`) work on 1.13.4.

`make brew-check` now passes. Two things surfaced that are worth carrying:

- **obsidian-cli exits 0 on an unknown command and on a missing required
  argument**, printing the error to stdout. `check_obsidian` is unaffected —
  `version` is real and still exits 1 when the app is down (re-verified on
  1.13.4) — but a future extension of that check gated on `$?` would pass
  forever after an upstream rename. Recorded at the call site.
- **`brew` reports a `libtiff, webp` circular dependency** on every invocation.
  Not a failure — `brew-check` passes through it — and its documented fix is
  `brew uninstall --ignore-dependencies --force libtiff webp && brew install`,
  which briefly breaks every image-handling formula depending on them. Left
  alone deliberately; take it during a `/upgrade-deps` pass, not a detach.

---

### WP13 — Network hygiene

Re-rated down from the initial pass — none of this is currently breaking anything,
but two items are **not runnable headlessly** and must happen before detach.

**Both headless items are done (2026-07-31).** `RouteAll` is now `false`, verified
via `tailscale debug prefs`, and the serve conf carries the Lima-mux comment —
`make tailscale-serve-check` still reports 3 bindings in sync. The `idss-mysql`
row is **withdrawn**, not deferred: it is one of the four IU work containers the
owner has ruled untouched, so the accidental control (no `tcp:3306` grant) stands
as the only control. Everything remaining in this package is Lane 3 (L3.6).

| Item | Action | Headless? |
|-|-|-|
| ~~`idss-mysql` binds `0.0.0.0:3306`~~ | **Withdrawn** — IU work container, ruled untouched. Every sibling container is already loopback-bound; only the absence of a `tcp:3306` ACL grant keeps the tailnet out, which is an accidental control rather than a deliberate one. Revisit only if the work-stack boundary moves. | n/a |
| en0 negotiating `100baseTX` on a 1 Gb/s NIC | Swap the cable. Error counters are clean (0 Ierrs/Oerrs/Coll over 48.2 M packets), so this is a stable negotiation to 100, not a dirty link. Verify `ifconfig en0 \| grep media` → `1000baseT`. | physical |
| No DHCP reservation | Reserve `5c:e9:1e:ec:5a:6e → 192.168.1.100` on the Fritz!Box. Prefer a reservation over `networksetup -setmanual` — the router stays the authority for gateway/DNS. | router |
| Wi-Fi Private Address rotating | `0a:31:ca:27:7c:6d` is locally-administered. Turn off Private Wi-Fi Address for this SSID. **No CLI exists** — System Settings → Wi-Fi. Keep Wi-Fi enabled: it is the only failover if the wired path dies, and with the screen gone that would be total loss of access. | **no — pre-detach only** |
| ~~`RouteAll: true`~~ | **Done** — `tailscale set --accept-routes=false`, `RouteAll: false` confirmed. No peer advertised anything, so nothing changed observably; the latent hazard removed is any peer advertising a subnet overlapping the mini's own, silently pulling local traffic out through the tailnet. (The original "homelab, one L2 hop away" framing was **wrong** — measured in §3b, they are on different networks.) **No declared-state file backs this** — the menu bar can flip it back and nothing asserts otherwise, so re-check after any Tailscale reinstall or re-auth. Recorded in `CLAUDE.md`; a heartbeat assertion was deliberately not added (see below). | yes |
| ~~`tailscale-serve.mini.conf` comments~~ | **Done** — both rows now name their real terminus. Verified rather than copied from the plan: `lsof` shows `ssh` PID 1448 (the Lima port-forward mux) holding both `127.0.0.1:4050` and `127.0.0.1:5173`, backed by the `rb-api` and `dashboard-ui` containers. | yes |

**Deferred: a `RouteAll` assertion in `devhost-health-check.sh`.** It looks like a
two-line addition and is not. `_ts_snapshot` emits a fixed three-field line and
`check_tailscale` reads the expiry with `days=${out##*|}` — the *last* field — so
a fourth field silently reassigns the expiry check to the new value. That is a
regression in a monitor validated hours ago, traded for an assertion whose failure
mode requires a second, deliberate change (a peer starting to advertise a subnet)
before it costs anything. Take it with the next change that touches the snapshot's
parsing, not on its own.

---

### WP14 — Dev-app reachability and the agent lane

**Where:** mini + dotfiles. The clean door is the one part of this system that is
fully working — the problems are its missing fallback, two lying registry entries,
and the fact that every agent is running in the lane the docs say not to use.

**The clean door is healthy, verified end to end:**

| Check | Result |
|-|-|
| `DEV_DOMAIN` | `mini.jkrumm.com`, seeded |
| `caddy list-modules \| grep dns.providers` | `dns.providers.cloudflare` **present** — the xcaddy build survived |
| Wildcard cert `CN=*.mini.jkrumm.com` | expires Oct 27 2026 — **88 days** |
| Apex cert `CN=mini.jkrumm.com` | expires Oct 28 2026 — 89 days |
| `dig` wildcard / apex / `apps.` / `health.` | all → 100.87.73.3 |
| ACL grant | rule 3 grants `(443,443)` from 4 sources incl. the MacBook |
| Registry | 18 apps, **zero skipped blocks**; tracked `config/Caddyfile` and live `/opt/homebrew/etc/Caddyfile` produce byte-identical registries |

The feared skip cases do not exist here. The retired `whisper.test` — the real
two-`reverse_proxy` case — is commented out and inert.

**14a — Zero port doors are deployed.** `~/.config/caddy-tailnet.ports` contains
only comments: no `portdoor`, no `exclude`. The generated `tailnet.caddy` defines the
`(tailnet)` snippet and never imports it. The "zero-dependency fallback that must
survive door 2 breaking", documented in CLAUDE.md as permanent, **is not deployed
for a single app**. Every app currently depends on one Cloudflare token, one DNS
module and one wildcard cert, with nothing behind them. The pre-migration file
`~/.config/caddy-tailnet.ports.pre-registry` shows four apps that used to have port
doors (argo 7715, basalt-playground 7710, modelpick 7727, jkrumm 7728) — they were
lost silently in the registry-v2 migration.

Restore two or three, choosing ports nothing else binds (the port-squatting hazard
against `tailscale serve` and `0.0.0.0`-binding dev servers is why this is opt-in
per app in the first place).

**14b — Two registry entries lie permanently.**

- **`rb`** is registered at 7730, but nothing binds 7730. rb's API is alive on
  `localhost:4050`, and the working door is the `tailscale serve` row
  `:7730 → 127.0.0.1:4050`. Point the Caddy block at 4050 or drop it and rely on
  the serve row.
- **`photoflow`** (7717) can never work — `photo-flow` lives on the MacBook, not the
  mini, and has no LaunchAgent here. Dead entry.

Both make the landing page's live-status column report red for things that are not
actually broken, which trains you to ignore it.

**14c — Every agent is in the wrong lane.** `claude agents --json` shows **8 live
agents** (free-planning-poker, linewatch, dotfiles ×2, basalt-ui ×2, clawbar,
research-gateway), ages 3 minutes to 20 hours. **All 8 are `"kind": "interactive"`.
Zero are `"kind": "background"`.** Every one traces back to PID 89992, the single
herdr server — so **one `kill -9` on that PID destroys all 8 agents and 20 hours of
work at once.** `rd agents` prints the warning itself ("'interactive' agents die
with their connection; durable work belongs in 'bg'") and it is being ignored in
practice. Given this machine has already OOM-killed that exact PID once (WP3), this
is the largest live risk to work in flight — and it needs no new code, because
`rd bg` exists and already routes around the keychain trap.

**14d — `rd agents` NAME column is useless.** Every row prints `?`:

```
  LANE     NAME   STATUS    CWD                            PANE / ID / SINCE
  herdr    ?      working   ~/SourceRoot/research-gateway  wG:p6
  herdr    ?      idle      ~/SourceRoot/dotfiles          wG:pC
```

Root cause verified against the raw socket API: `herdr agent list` returns no `name`
field at all for hand-started agents — only `herdr agent start '<name>'` (what
`rd work` does) assigns one. `cmd_agents` does `clip(a.get("name"), 24)` → `None` →
`"?"`. Meanwhile `rd read <agent>` and `rd say <agent>` both expect a name:

```
rd read clawbar   -> {"error":{"code":"agent_not_found", ...}}
rd read wQ:p1     -> works, returns live pane content
```

Degraded, not dead — the pane id is right there in the last column — but the error
message reads like the agent died rather than "wrong identifier", and from a
screenless MacBook you rediscover this by trial and error every time a pane id
churns. Two small fixes: have `cmd_agents` fall back to `terminal_title_stripped`
(herdr already carries a readable task title) or `pane_id` for the NAME column, and
have `cmd_read`/`cmd_say` accept a repo-name match against `herdr agent list` the
way `cmd_work` already does. Also missing: no `rd stop`/`rd kill` — you can start
and read an agent but not end one without attaching.

**14e — Correct collie's acceptance assertion in CLAUDE.md.** The hardening is
**intact** — `COLLIE_PUBLIC_HOSTS`, `COLLIE_SKIP_SERVE=1`, `COLLIE_MULTI_SESSION=off`
and `COLLIE_HOST=127.0.0.1` are all present in PID 26922's actual environment, so
the plist's `set -a; . .env` is working. But CLAUDE.md's acceptance test says "a
spoofed Host must return 403" **without naming a path**, and run against `/` it now
returns 200 — the SPA shell is served unguarded (CSP-locked, `default-src 'self'`).
The guard only fires on real API routes:

```
/api/snapshot   loopback=200  evil=403  ported=200  bare=200  wrongport=403
/api/config     loopback=200  evil=403  ported=200  bare=200  wrongport=403
POST /api/tab   evil=403; evil Host + matching evil Origin (rebind sim) = 403
```

Pin the assertion to `/api/snapshot`, or the next auditor concludes the guard broke.
The audit that produced this document made exactly that mistake and had to correct
itself.

**14f — Reap 9 orphaned `herdr server` processes** (PIDs 80579, 81867, 82312, 83348,
84076, 85672, 94754, 95853, 96411 — all PPID 1, all Jul 27, ~3d18h old). They hold
sockets under `/tmp/hcap/*/`, so they are leftovers from a scripted pty-capture run,
not competing servers. Harmless to the live path, but they make `ps | grep herdr`
unreadable during an incident — which is exactly when you would be reading it. This
is the same set WP3 kills; the anchored-pattern safety note there applies.

**Screen Sharing, confirmed.** `screensharingd` running (PID 77302); port 5900 open
on both loopback and 100.87.73.3; ACL rule 0 grants `(5900,5900)` from the mini
itself and the MacBook only — correctly scoped, no `tag:client` exposure. The
FileVault limit is confirmed fatal for break-glass: at the pre-boot prompt there is
no user session, no launchd user domain, no Tailscale and no `screensharingd`, so
both VNC and the dummy plug are useless there. This is the fifth independent
confirmation of the §3 coupling.

**The `:8443` Funnel is public and unauthenticated.** Probed: HTTP/2 200,
`server: nginx/1.31.3`, serving a built Vite SPA titled "frontend". No auth
challenge, no redirect — anyone who knows the hostname gets the app shell. `/api/`
returns 404 and the data layer (`dashboard-api`, bound `127.0.0.1:2720`) is in no
serve row, so the exposure is the bundle, not the data. Whether the API behind it
authenticates was not probed.

**Acceptance:** `curl --resolve` against each restored port door returns the same
status as its clean door; `rd agents` prints a usable identifier in NAME;
`rd read <repo-name>` resolves; `claude agents --json` shows the long-lived work in
`"kind": "background"`.

---

### WP15 — brain / LiveSync decision

The vault is healthy — git clean, in sync with origin, and `com.jkrumm.brain-backup`
fires nightly at 03:30 (runs=7, last exit 0, pushed today) over the cache-backed
credential helper with no biometric dependency. **Backup works.**

What is broken is cross-device *sync*. Every LiveSync replication trigger is `False`
(`liveSync`, `syncOnStart`, `syncOnSave`, `syncOnEditorSave`, `syncOnFileOpen`,
`periodicReplication`, `remoteType=''`), CouchDB on homelab has not been written
since 2026-07-21, and the vault gained 13 commits in that window (the audit said
14; recounted on execution).

**Recommendation: retire LiveSync** and fix the three docs that claim it
(`brain/AGENTS.md:17`, `brain/CLAUDE.md:54`, the `brain` row in
`config/global.CLAUDE.md`). The MacBook holds no brain checkout at all, so there is
currently no second device to sync with — the feature asserts a property it cannot
deliver.

If kept instead: set `periodicReplication`, `syncOnSave` and
`keepReplicationActiveInBackground` true in the UI (needs a screen), point it at
`http://100.85.139.104:5984` or `homelab.dinosaur-sole.ts.net` rather than
`couchdb.jkrumm.com` (a public name that does not resolve during a WAN outage even
though homelab is one L2 hop away), and do the first reconciliation with a screen
attached and the vault git-clean — a 10-day delta with `resolveConflictsByNewerFile`
can produce `*.conflicted.md` files, which are gitignored and therefore invisible to
both git and the nightly backup.

**Credentials:** the "backed up nowhere" claim is refuted —
`op item list --vault homelab` returns an item titled `couchdb`. The narrow real
question is whether the **end-to-end encryption passphrase** (`encryptedPassphrase`
in `data.json`, distinct from the CouchDB HTTP password) is in that item's
`notesPlain`. Check that one value and add it if absent. Drop the
un-ignore-plugin-binaries idea — plugins reinstall from the community store in
minutes, which beats 11 M of binary churn in a 5.5 M `.git`. Write "plugins are
reinstalled from the store" into the recovery notes.

---

### WP16 — UPS

Any USB HID Power Device–class UPS (APC Back-UPS, CyberPower, Eaton) — macOS picks
it up with no driver. **Sequence matters:** attach → confirm it appears in
`pmset -g ps` / `pmset -g ups` → *then* set halt thresholds.
`haltlevel`/`haltafter`/`haltremain` do not appear in `pmset -g cap` today and only
become settable once the hardware exists:

```bash
sudo pmset -a haltlevel 20 haltafter 5 haltremain 10
```

Honest framing: a UPS converts most outages into non-events and long outages into a
*graceful* shutdown — which protects APFS and colima's VM image, and is precisely
what prevents the dirty-start failure WP7 works around. It does **not** solve
unattended restart; a graceful shutdown lands at the same auth screen. Damage
control plus a prerequisite, not the answer.

---

### WP17 — Detach

Gated on WP2, WP4, WP6, WP7, WP8 and WP14 acceptance tests all passing. Then: pull the
monitor, leave the HDMI dummy plug in, power-cycle at the wall once as final proof,
and confirm from the MacBook within 10 minutes that `ssh mini`, `claude agents`,
`docker ps`, `/usr/local/bin/obsidian version`, `vnc://mini` and
`https://<app>.mini.jkrumm.com` all answer with no human intervention.

---

## 5. Reclaimed resources

| WP | RAM | CPU | Disk |
|-|-|-|-|
| 3 — leaked python | — | 1.00 core (919 CPU-min accrued) | — |
| 3 — Clawbar | 0.66 GB | 0.96 core (1332 CPU-min accrued) | 70 MB |
| 3 — Chrome + Helium | measure; summed RSS 13.8 GB across 122 procs **overstates** it | ~0.2 core | — |
| 3 — 9 orphan herdr servers + cmux shells | ~0.14 GB | negligible | — |
| 8 — Teams, Spotify, Claude.app, Raycast, TickTick, WhatsApp, MacWhisper, cmux, Ghostty | ~2.8 GB | — | — |
| 8 — Karabiner + G HUB extensions off | ~0.49 GB / 28 procs | ~0.02 core | — |
| 8 — static wallpaper | 0.23 GB (WindowServer) | 0.05 core | 2.3 GB (10f) |
| 10a — docker prune + fstrim | — | — | **measure** — 90.6 GB "reclaimable" double-counts against 76 GB used; realistically 50–60 GB |
| 10b — package + app caches | — | — | ~35 GB |
| 10c — image-gen cargo target | — | — | 6.4 GB |
| 10d — stale node_modules | — | — | up to 13.6 GB |
| 10e — JetBrains pre-2026 state | — | — | ~12 GB (enumerate first) |
| 10f — home archive + installers | — | — | ~9 GB |

Realistic totals: **~4–5 GB of RAM measured** (not the 17 GB naive RSS sums suggest),
**two full cores**, and **~118 GB of disk** — 70% → roughly 57%. The two cores are
the only certain number; everything else needs measuring after the fact.

---

## 6. Open questions

| Question | Recommendation |
|-|-|
| Uninstall Chrome, or only quit it? | **Quit only** — which your decision already settles. Worth recording why it would have been risky anyway: `~/.cache/puppeteer/chrome/` holds only an *unextracted* zip while `chrome-headless-shell` is unpacked, which points at chrome-devtools-mcp resolving the installed `/Applications/Google Chrome.app`. Uninstalling would likely break `/browse`. |
| The `:8443` Funnel (public internet, no auth) | **Inspect, then most likely delete.** Only the static frontend is funneled — `dashboard-api` is bound `127.0.0.1:2720` and is in no serve row, so an external browser cannot reach the data layer. What is public is the built JS bundle. Check what it embeds (endpoints, tokens, internal hostnames) before deciding; the hostname is permanently discoverable in Certificate Transparency logs, so obscurity is not a control. |
| The four IU work containers (dashboard-api 1.15 GB, dashboard-ui, idss-mysql up 6 d, idss-valkey) | Your call — outside the "leave the work stack alone" boundary only if you want it to be. ~1.5 GB, and stopping them takes the Funnel endpoint down. `idss-mysql` may hold un-persisted state. Drive it through the owning repo's Makefile, never raw docker. |
| GitHub PAT (`op://mini/github/token`) has **no expiry** and `Contents: read+write` on **all** repositories | **Reduce scope** rather than adding an expiry. An expiry reintroduces exactly the silent-rot failure the cache-backed helper was built to replace; scope reduction has no such failure mode. If an expiry is set anyway, pair it with weekly `make remote-dev-doctor` — the only check doing a real `git push --dry-run`. |
| Should durable agents auto-restart after a reboot? | **Decide explicitly.** After WP4 a launchd-supervised `claude --bg` no longer needs the GUI session, which makes "yes" cheap. If the answer is "no", nothing to build. |
| Time Machine (currently **no destination configured at all**) | **Configure it, after WP10.** Adding a network destination to a machine already writing 264 GB/day would add substantial I/O — fix the write pathology first. |
| Should a Tauri desktop app be built on a permanently headless mini? | Probably not. If only `gateway/` (220 K) belongs here, 10c stops being a recurring 6.4 GB. |

---

## 7. Deliberately not doing

- **Not uninstalling any app.** Your decision — the mini may be a headful
  workstation again. Everything in WP8 stops things *starting*, nothing removes
  them, and the Brewfile is therefore left untouched so `make brew-check` keeps
  describing the machine truthfully.
- **Not converting herdr or colima to root LaunchDaemons.**
  `sudo brew services start herdr` runs the server as root, changing ownership of
  every socket, pane process, the `rd` socket API and `HERDR_PLUGIN_STATE_DIR` — and
  with FileVault on it still cannot run pre-unlock. colima straddles by nature: its
  VM and socket live under `$HOME`. Auto-login (WP6) makes the conversion
  unnecessary, which is the main argument for auto-login over the alternative.
- **Not moving sideclaw to a LaunchDaemon.** It was misclassified as keychain-free:
  `SIDECLAW_WORKER_BACKEND=max` in its `.env` means its workers shell out to `claude`
  on the Max subscription, so a daemon reproduces the "Not logged in → silent API
  billing" failure. Revisit after WP4.
- **Not stripping `SSH_AUTH_SOCK` from `config/zsh/secrets.zsh`.** The
  GitLab-hangs finding was refuted by direct measurement twice. This would break
  something that works *and* remove the agent from Screen Sharing sessions, which the
  comment at :6-9 deliberately preserves.
- **Not removing `/usr/local/bin/op` from the mini.** It works, and removing it
  breaks `make secrets-seed`, `secrets-rotate` and `github-config` if ever run there.
  It is an unmanaged 2023 pkg install absent from the Brewfile — worth *declaring*,
  not deleting.
- **Not disabling SIP** to force `systemextensionsctl uninstall`. macOS 26 offers a
  supported path (`systemextensionsctl gc`, then System Settings).
- **Not turning Spotlight off wholesale.** `mds_stores` has accrued 194 CPU-minutes
  over 6.4 days — 2.1% of one core, against Clawbar's 1332 and the leaked python's
  919. The "38.8% CPU" reading was a transient. Also, `.metadata_never_index` is
  documented for *volume roots*; whether it is honoured in an arbitrary directory on
  macOS 26 is undocumented.
- **Not `colima delete` + recreate** to shrink the datadisk. `colima.yaml` declares
  `disk: 60` against a live 100 GiB disk — a recreate silently halves the ceiling and
  destroys every volume.
- **Not `docker volume prune`.** Eleven volumes are active; `idss-mysql` holds real
  data.
- **Not swapping to Homebrew `tailscaled`.** The current build is correct (macsys
  standalone, root system extension, state in `/Library/Tailscale`). A re-auth
  changes device identity and would silently orphan `tag:devhost`,
  `tag:iu-dashboard-funnel`, both `tailscale serve` rows, and every MagicDNS-keyed
  dev door. Only consider it if WP2's logout test fails.
- **Not "fixing" `brew services list` showing caddy/dnsmasq as `none`.** They are
  root system daemons and running. Acting on the misreading creates a second caddy
  fighting for :443.
- **Not chasing the `caffeinate` assertions.** They are Claude Code's own
  `caffeinate -i -t 300`, self-releasing, observed releasing on their own.
- **Not installing smartmontools** for NVMe wear numbers. Apple's controller does not
  expose the counters on Apple Silicon; `SMART: Verified` is a binary flag.
- **Not un-ignoring `.obsidian/plugins/`** in the brain vault, and **not touching
  `~/Obsidian/Vault`** — CLAUDE.md designates it a cold backup to keep closed.

---

## 8. What was not checked

- **SMAppService / BTM background items.** `sfltool dumpbtm` returns zero bytes
  without root. Everything here derives from launchd, the legacy login-item list and
  system extensions. Run it in WP2 and diff.
- **Headless display behaviour — and the two audits disagree.** A Dell U4919DW
  (5120×1440, Main Display) has been attached continuously since Jul 24, so the
  no-EDID case has never been exercised. The research pass concluded macOS does *not*
  synthesise a usable framebuffer without EDID and the dummy plug is required; the
  reachability audit expected Apple Silicon + macOS 26 to provide a virtual
  framebuffer with the plug merely pinning resolution. **Neither is verified** — the
  research sources were all rate-limited, and confirming it on the machine requires
  unplugging the monitor. At 5 EUR the plug settles the question by making it moot;
  fit it in WP2 and then test by actually detaching, which is the only real evidence
  either way.
- **Tailscale before-login.** The macsys variant *should* run before login per
  Tailscale's own variants table, but that is a product claim, not an observation of
  this machine. WP2's logout test is the first real evidence.
- **The caddy cold-boot path.** The include was born Jul 29; last boot Jul 24. The
  listener-failure mode was reproduced synthetically (`[Errno 49]`), not observed
  here.
- **Whether `/browse` needs the installed Chrome.app.** The puppeteer cache evidence
  is suggestive, not conclusive.
- **restic coverage of the NAS share.** Archiving there is storage until confirmed.
- **Whether Kuma's `MacMini Secret Seed - Push` history shows gaps.**
  `com.jkrumm.secrets-freshness` reports `runs = 2` against ~6 due firings in a
  6d10h uptime, which may be launchd coalescing calendar jobs on a thrashing system
  rather than a fault. The cache itself is healthy (sealed 2026-07-30, 136/136 refs,
  zero drift).
- **What the `:8443` dashboard bundle embeds.** The exposure question turns entirely
  on this.
- **Whether the `:8443` dashboard's API authenticates.** The Funnel serves the
  bundle publicly; `dashboard-api` is loopback-bound and in no serve row, so the data
  layer is not directly reachable — but its own auth was not probed. It is a work
  service, so this belongs to the IU side.
- **`rd say`.** Not tested — it mutates a running agent, and 8 were live.
- **`ssh mini 'claude --bg …'` keychain trap.** Documented and worked around in
  `cmd_bg`; not re-verified this session, since verifying it means spawning a daemon.
