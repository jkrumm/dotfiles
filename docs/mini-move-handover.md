# Moving the mini to a new LAN — handover

Written 2026-07-31, superseding the FileVault half of `mini-headless.md` §3.
Companions: `mini-headless.md` (reasoning, 17 work packages),
`mini-headless-checklist.md` (the human lanes).

## Two owner decisions, taken 2026-07-31

| Decision | Consequence |
|-|-|
| **Keep FileVault.** Use macOS 26's pre-boot SSH unlock instead of WP6. | Recovery is two remote steps, not zero. WP4 stops being a hard gate. |
| **The new LAN is separate from homelab's.** | There is **no remote break-glass**. See the gap below. |

## The gap those two decisions create, stated plainly

Pre-boot SSH unlock has **no Tailscale** — tailscaled's state lives on the Data
volume that is still encrypted. The unlock must arrive over the mini's **own
LAN**, by IP or Bonjour name. homelab is on `192.168.178.0/24` and cannot reach
it (measured; they meet only over the tailnet).

So: **if the mini hard-reboots while nobody is at its location, it stays down
until someone is physically on that LAN.** A UPS shrinks how often that happens;
it does not remove the case. Three ways out, in cost order:

1. **Accept it.** Buy the UPS (WP16), and treat a long outage as a trip.
2. **Put any always-on tailnet node on the mini's new LAN** — a Pi Zero, an old
   phone on a charger, a spare mini. It needs to do exactly one thing: be
   reachable over Tailscale and run `ssh`. That restores unlock-from-anywhere for
   ~€20–50 and is the single highest-leverage thing on this page.
3. **Reverse the FileVault decision** (WP6 as originally planned). Only truly
   unattended option; costs the "power button doesn't hand over a logged-in
   desktop with `~/.config/sops/age/keys.txt`" guarantee.

## Before shutdown — in this order

### 1. Save the work that dies with the machine

Six agents are live in herdr, several mid-task. **All of them die on shutdown**
(they are `kind: interactive`, children of one herdr server). And as of
2026-07-31 there is uncommitted or unpushed work in eight repos:

```
argo modified=1 · clawbar modified=5 · free-planning-poker unpushed=1
homelab modified=1 · homelab-private modified=1 · jkrumm.com modified=1
linewatch UNPUSHED=17 · modelpick modified=1
```

`linewatch` with **17 unpushed commits** is the one that matters. Push it.

```bash
for d in ~/SourceRoot/*/; do [ -d "$d/.git" ] || continue
  (cd "$d" && git status --porcelain | grep -q . && echo "== $(basename "$d")" && git status --short)
done
```

### 2. Confirm the things that make the machine come back

| Check | Command | Expected |
|-|-|-|
| Remote Login on | System Settings → General → Sharing | **on** — this is what serves the pre-boot sshd |
| Secure Token | `sysadminctl -secureTokenStatus jkrumm` | ENABLED ✓ (verified) |
| Wired ethernet | `ifconfig en0` | active — Wi-Fi creds live on the encrypted volume, so **pre-boot unlock over Wi-Fi is unreliable by design** |
| Tailscale key expiry | Tailscale console | **must be disabled — still outstanding, 70 days** |
| Power-on after outage | `system_profiler SPPowerDataType \| grep 'Power Loss'` | currently **No** — WP5 not done |

**WP1 is now the single most dangerous outstanding item.** If the node key
expires at a location with no monitor and no LAN jump host, re-auth needs a
browser *on the mini*. Do it before the machine moves. Same console visit covers
`localhost` (phone) and `IUGMXK9P6DY1XC`, both at **5 days**.

### 3. Join the new LAN's Wi-Fi *before* the move

Wi-Fi is the only failover if the new wired path is bad, and with no screen a
dead wired link is total loss of access. The SSID must already be in the
preferred list — it cannot be added headlessly.

### 4. Shut down cleanly

```bash
make colima-stop     # brew services stop — a dirty Lima image is what WP7 works around
```

Then shut down from the Apple menu while the screen is still attached. Do **not**
pull the plug.

## At the new location

1. Plug in **wired ethernet** and power. Press the power button.
2. Find the new LAN IP — the new router's DHCP table, or try Bonjour first:
   `ssh jkrumm@mini.local` (LocalHostName is `mini`; whether mDNS answers
   pre-boot is **unverified**, so have the router's table ready).
3. **Set a DHCP reservation immediately** for `5c:e9:1e:ec:5a:6e`. Without a
   stable LAN IP, every future unlock starts with a network scan.
4. Unlock: `ssh jkrumm@<lan-ip>`, enter the **account password** (not the
   recovery key). Expect the session to drop — that is success. Password auth
   only; keys are on the encrypted volume.
5. Wait ~30 s, then `ssh mini` over Tailscale should work.
6. **Log in to the GUI.** Unlock is not login — macOS stops at the login window,
   and the 15 `gui/501` services (herdr, sideclaw, litellm, hermes gateway, the
   colima brew service, devhost-health, collie, Obsidian) are all still absent.
   Screen Sharing (`vnc://mini`) is the intended path; see the caveat below.
7. Verify: `make remote-dev-doctor` from the MacBook, then
   `ssh mini 'make devhost-health-check'`.

### The one unverified link in that chain

Step 6 depends on Screen Sharing working **at the login window**.
`com.apple.screensharing` is a **system-domain** job, which says it should — but
`mini-headless.md` §1 asserts the opposite, and neither claim has been tested on
this box. **L3.2's logout test settles it, and it should be done while the screen
is still attached.** If Screen Sharing does *not* answer at the login window,
the keep-FileVault path is unlockable but not usable remotely, and WP6 comes back
onto the table.

## Handover prompt

```
Continue the Mac mini headless work. Read these three, in order, before acting:
  ~/SourceRoot/dotfiles/docs/mini-move-handover.md   (start here — supersedes the
                                                      FileVault half of the plan)
  ~/SourceRoot/dotfiles/docs/mini-headless.md        (reasoning; §3b is new)
  ~/SourceRoot/dotfiles/docs/mini-headless-checklist.md  (human lanes 2 and 3)

Owner decisions, already taken — do not re-litigate:
  - KEEP FileVault. macOS 26 unlocks it over SSH at pre-boot (verified against
    this machine's own `man 7 apple_ssh_and_filevault`). WP6 is withdrawn as a
    requirement; it stays available as a fallback.
  - The mini's new LAN is SEPARATE from homelab's, so there is no LAN jump host
    and no remote break-glass today. The open question is whether to add a cheap
    always-on tailnet node on that LAN.
  - Apps are stopped from booting, never uninstalled. The IU work stack and its
    four containers are untouched.

Still outstanding, highest first:
  1. WP1 — Tailscale key expiry, six devices, two at 5 days. Console-only, from
     the MacBook. Nothing else matters if the mini's key lapses.
  2. L3.2 — the logout test. Must be a real LOGOUT, not a reboot: with FileVault
     on there is no "booted but not logged in" state reachable by rebooting, so a
     reboot test silently measures the logged-in case and returns a false pass.
     It answers the one unverified link: does Screen Sharing answer at the login
     window? The whole keep-FileVault path depends on it.
  3. WP5 — power-on layer (`pmset autorestart 1`). Sudo from the MacBook.
  4. WP8 — stop things booting; RadioSilence first (orphaned content-filter
     network extension, prime suspect for any unexplained network failure, and a
     LAN move is exactly when one would appear).
  5. WP10 remainder — ~12 Gi short of the 380 Gi bar. JetBrains state (12 GiB) or
     the NAS archive (8.6 GiB); either clears it alone.
  6. WP16 — UPS. More important now, not less: it is what keeps the no-remote-
     break-glass gap rare.

Hard constraints on this machine:
  - You are ON the mini. Secrets backend is `cache`. NEVER run `op` directly —
    it hangs. Use `secrets-run`.
  - Live Claude agents are the owner's real work. Derive the herdr server PID
    fresh before any pkill; the orphan-reaping pattern is anchored on
    `^/opt/homebrew/bin/herdr server` so it cannot match the live server at
    `/opt/homebrew/opt/herdr/bin/`.
  - Never run: `make setup`, `make secrets-seed`, `colima delete`,
    `docker volume prune`, `docker system prune`, or sudo anything.
    `make brew-upgrade` only with explicit consent.
  - Anything needing sudo, biometric, or a GUI dialog: add it to the checklist,
    do not attempt it.

Discipline: validate with `mcp__sideclaw__check`; `make hooks-test` after hook
edits; `make secrets-test` + shellcheck + the design-doc update after any
`secrets-run` edit. One commit per work package, conventional commits, no
attribution. Another agent may be working in dotfiles — check `rd agents` and
`git status`, and use explicit paths, never `git add .`. Report per package what
changed, the real acceptance result, and what you deferred and why. If an
acceptance test needs a human, say so — never fake a pass.
```
