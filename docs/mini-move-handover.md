# Moving the mini to a new LAN — handover

Written 2026-07-31. Supersedes the FileVault half of `mini-headless.md` §3.
Companions: `mini-headless.md` (reasoning; **§3b is new and load-bearing**),
`mini-headless-checklist.md` (the human lanes).

> **To run it, use `macbook-handover.md`.** This file holds the decision and its
> reasoning; that one sequences the remaining work into six ordered phases with the
> WP4 gate in the right place, and is written to be pasted whole as a prompt to a
> Claude session on the MacBook.

## The decision, and the reversal behind it

**Disable FileVault, enable auto-login (WP6).** This was decided *against* first
and reversed within the hour — the reversal is the useful part, so it is recorded
rather than tidied away.

macOS 26 really does unlock FileVault over pre-boot SSH (verified against this
machine's own `man 7 apple_ssh_and_filevault`; §3b). That looked like it made WP6
unnecessary. Two measurements killed it:

1. **Tailscale cannot run pre-boot — proven, not inferred.** Both
   `/Library/Tailscale` and `/Applications/Tailscale.app` are on `disk3s5`
   (`/System/Volumes/Data`, `FileVault: Yes`). The pre-boot sshd works because it
   ships on `disk3s1s1`, the Apple-signed sealed System volume, where no
   third-party app can live. So pre-boot unlock is **LAN-only**, and the new LAN
   has no homelab (`192.168.178.129`, a different network) and no other always-on
   tailnet node.
2. **Unlock is not login.** It leaves macOS at the *login window*. The 15
   `gui/501` services — herdr, sideclaw, litellm, hermes gateway, the colima brew
   service, devhost-health, collie, Obsidian — are still absent until someone
   logs in.

Together those mean no remote-access trick makes the keep-FileVault path
*automatic*. Even a jump node on the new LAN leaves two manual steps after every
power cut, forever. Auto-login is the only option that removes the human, and it
deletes the need for the jump node and the availability case for the UPS at the
same time.

**What is given up**, stated once and plainly: someone with physical possession
presses power and gets a logged-in desktop holding `~/.config/sops/age/keys.txt`
(189 B, 0600), which decrypts all 136 cached refs including the work exceptions.
Offline NAND extraction, recoveryOS and Target Disk Mode all remain gated; DFU
restore wipes rather than exposes. On Apple Silicon the SSD stays hardware-
encrypted either way — FileVault only controls what wraps the key, so
`fdesetup disable` is a Secure Enclave re-wrap, not a decryption pass over
672 GB. Effectively instantaneous, no data loss.

## The pre-move path: WP4 → WP5 → WP6

**Strictly ordered. WP6 must not start until WP4's acceptance passes.**
Auto-login does not unlock the login keychain, so if Claude Max auth is still on
the keychain when FileVault goes off, every agent silently falls back to API
billing while still reporting healthy in `claude agents`.

### WP4 — Claude Max auth off the login keychain (gate)

One open verification is already closed: CLI **2.1.220** has `claude setup-token`
("Set up a long-lived authentication token"), and **`CLAUDE_CODE_OAUTH_TOKEN`**
is confirmed present in the shipped binary. It must be that variable, never
`ANTHROPIC_API_KEY` — exporting the latter flips billing to API credits, the
exact failure this fixes.

| Step | Who |
|-|-|
| `claude setup-token` in a present-human session on the mini | **human, at the mini** |
| Store as `op://mini/claude/oauth-token`; add to `dotfiles-private/headless.refs` with a T-classification note and to `docs/security-review.md` as a standing Max credential readable by anything that can call `secrets-run` | agent can draft, human commits |
| Push `dotfiles-private`, then from the MacBook: `git pull` there, then `make secrets-seed` | **human, MacBook, biometric** |
| Export it via `secrets-run` in whatever launches `claude` | agent |
| Drop the herdr-pane indirection in `remote-dev.sh` `cmd_bg` once proven | agent |

The `git pull` is not optional — the seed reads the **local** `headless.refs`, so
a ref added on the mini and left unpushed is silently omitted.

**Acceptance, from the MacBook:** `ssh mini 'claude --bg "echo ok"'` produces a
daemon reporting `loggedIn: true, subscriptionType: max` — **not** `Not logged
in`. The `claude auth status` assertion already exists in
`scripts/devhost-health-check.sh` and skips cleanly until this is wired.

### WP5 — power-on layer

`autorestart` is **0** today (`Automatic Restart on Power Loss: No`) — mains
returns and the machine stays dark. **This is a prerequisite for every option,
not just this one.** Sudo from the MacBook:

```bash
sudo pmset -a autorestart 1 && sudo pmset -a autorestartatconnect 1
sudo pmset -a powernap 0
```

Leave alone: `womp 1`, `tcpkeepalive 1`, `ttyskeepawake 1`, `sleep 0`.

**Acceptance:** `system_profiler SPPowerDataType | grep 'Power Loss'` → `Yes`.
Check that, not just `pmset -g custom`.

### WP6 — FileVault off, auto-login on

**Human, physically at the mini. Gated on WP4 acceptance.**

1. `sudo fdesetup disable` — interactive volume-owner prompt, cannot be scripted.
   `jkrumm` has a Secure Token and is a volume owner (verified), so it succeeds.
2. `sudo sysadminctl -autologin set -userName jkrumm` — the supported mechanism.
   Do **not** hand-write `/etc/kcpassword`.
3. Reboot. Decisive test from the MacBook: `rd bg` an agent, confirm
   `claude auth status` → `loggedIn: true, subscriptionType: max`. Expect the
   login keychain itself to be **locked** — that is what WP4 makes survivable.
4. Decide the three console-security settings explicitly rather than inheriting
   undeclared defaults: `askForPassword`; Screen Sharing → "only these users →
   jkrumm"; clear the legacy `/Library/Preferences/com.apple.VNCSettings.txt`.
5. Re-check the ACL's `dst` for :5900 is not `tag:mac`-wide.

**Acceptance:** power-cycle at the wall. Machine returns unattended; `ssh mini`,
`claude agents` on max billing, `herdr session list`, `docker ps`, `vnc://mini`.

**Rollback:** `sudo fdesetup enable` + `sudo sysadminctl -autologin delete`.
Re-enabling runs a real encryption pass and takes time — the asymmetry is
expected. The §3b pre-boot-SSH path remains the fallback if you ever do.

## Also before shutdown

### Save the work that dies with the machine

Six agents are live in herdr, several mid-task, all `kind: interactive` and all
children of one herdr server — **they die on shutdown.** As of 2026-07-31 there
is uncommitted or unpushed work in eight repos:

```
argo modified=1 · clawbar modified=5 · free-planning-poker unpushed=1
homelab modified=1 · homelab-private modified=1 · jkrumm.com modified=1
linewatch UNPUSHED=17 · modelpick modified=1
```

`linewatch` with **17 unpushed commits** is the one that matters.

```bash
for d in ~/SourceRoot/*/; do [ -d "$d/.git" ] || continue
  (cd "$d" && git status --porcelain | grep -q . && echo "== $(basename "$d")" && git status --short)
done
```

### WP1 — Tailscale key expiry (do this first, it outranks everything)

Still outstanding. Six devices; two at **5 days** (`localhost`/phone,
`IUGMXK9P6DY1XC`), the tablet at 19, the mini at 70. Console-only, from the
MacBook. If the mini's key lapses at a location with no monitor, re-auth needs a
browser *on the mini*.

### L3.2 — the logout test

Still worth doing even though FileVault is coming off: it is minutes of work and
it is the only thing that establishes whether Screen Sharing answers at the login
window — the fallback if FileVault ever goes back on. **A real logout, not a
reboot**: with FileVault on there is no "booted but not logged in" state
reachable by rebooting, so a reboot test silently measures the logged-in case and
returns a false pass.

### Join the new LAN's Wi-Fi

Cannot be added headlessly, and it is the only failover if the new wired path is
bad. With no screen, a dead wired link is total loss of access.

### Shut down cleanly

```bash
make colima-stop     # a dirty Lima image is what WP7's retry wrapper works around
```

Then shut down from the Apple menu while the screen is still attached.

## At the new location

With WP4→WP5→WP6 done, arrival should need no unlock at all: plug in wired
ethernet and power, press the button, and the machine boots to a live session
with all 20 services. Then:

1. **Set a DHCP reservation** for `<mini-en0-mac>` on the new router.
2. `make remote-dev-doctor` from the MacBook.
3. `ssh mini 'make devhost-health-check'`.
4. `ssh mini 'ifconfig en0 | grep media'` — was negotiating `100baseTX` on a
   1 Gb/s NIC with clean error counters; a new cable may or may not fix it.

If WP6 was *not* completed before the move, arrival falls back to the §3b path:
find the LAN IP from the router's DHCP table (or try `ssh jkrumm@mini.local` —
LocalHostName is `mini`, but whether mDNS answers pre-boot is **unverified**),
then `ssh jkrumm@<lan-ip>`, type the account password, expect the session to
drop — that is success — then log in over Screen Sharing.

## Open questions

| Question | Status |
|-|-|
| ~~Does a UPS make long outages *worse*?~~ | **CLOSED 2026-07-31 — not buying one.** Owner's call, so the question is moot rather than answered; nothing was tested on this hardware. Availability is unaffected (WP6 auto-login + WP5 `autorestart 1` is the mechanism, never the UPS). What is given up is integrity on a hard cut, which makes `colima/colima-start.sh`'s bounded-retry wrapper the only guard against a dirty Lima image. If a UPS is ever bought, run that test before setting any halt thresholds. |
| Should durable agents auto-restart after reboot? | After WP4 a launchd-supervised `claude --bg` no longer needs the GUI session, which makes "yes" cheap. Decide explicitly. |
| The `:8443` Funnel is public and unauthenticated | Inspect the bundle, then most likely delete. |
| GitHub PAT has no expiry and `Contents: read+write` on all repos | Reduce scope rather than adding an expiry. |
