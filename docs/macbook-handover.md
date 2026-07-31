# MacBook handover — finish the mini detach

Written on the mini 2026-07-31 for a Claude session **on the MacBook**. Paste this
whole file as the prompt, or open it and work down.

Companions: `mini-move-handover.md` (the decision), `mini-headless.md` (reasoning),
`mini-headless-checklist.md` (every human step, in full).

---

## What this is for

The mini's detach is at the point where the remaining work needs the MacBook — sudo
over ssh, a biometric `op` session, the Tailscale admin console, and one acceptance
test that **structurally cannot be run from the mini**. An agent on the mini already
did its half; everything below needs the machine with a human in front of it.

**Read the phases in order. Phase C is gated on Phase B passing.** Getting that
wrong means every agent on the mini silently bills API credits forever while still
reporting healthy in `claude agents`.

Sudo on the mini runs from here, never there:

```bash
ROOT_PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm) && \
  ssh mini "echo '$ROOT_PW' | sudo -S <cmd>"
```

`sudo -S` reads stdin, so no `ssh -t` — a `!`-prefixed Claude Code command gets no TTY.

---

## Phase 0 — WP1, before anything else

**The mini's Tailscale key is NOT disabled. It expires 2026-10-10.** If it lapses at
a location with no monitor, re-auth needs a browser *on the mini* — i.e. carrying a
screen and keyboard back to it. This is the one failure with no remote recovery, and
it is the reason WP1 outranks the entire rest of the plan.

Tailscale admin console → Machines → ⋯ → **Disable key expiry**, on all six:

| Device | Days left (2026-07-31) |
|-|-|
| `IUGMXK9P6DY1XC` (work) | **4** |
| `localhost` (phone) | **4** — collie access dies with it |
| `TB330FU` (tablet) | 19 — holds the `tag:tablet` dev-door grant |
| **`mini`** | **70** — the unrecoverable one |
| `apple-tv` | 69 |
| `TV` | 108 |

Verify — expect `None`:

```bash
ssh mini '/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["KeyExpiry"])'
```

---

## Phase A — at the mini, physically (WP4 mint)

Must happen while a human is at the machine, and **before** Phase B.

1. `claude setup-token` in a present-human session on the mini.
2. Store the value as **`op://mini/claude/oauth-token`** in 1Password. Create the item
   *before* committing the ref — the seed reads every ref and fails closed, so a
   listed ref with no item breaks the whole reseed, not just that line.
3. In `~/SourceRoot/dotfiles-private` on the mini, commit and push the two files an
   agent already drafted into the working tree:
   - `headless.refs` — the ref plus its T-classification note
   - `docs/security-review.md` — the standing-credential section

   They are **uncommitted**. An uncommitted edit is one stray `git checkout` from
   gone, and an unpushed one is silently omitted from the seed in Phase B.

---

## Phase B — the gate (MacBook)

### B1 — negative control first, and do not skip it

Before seeding, run the acceptance test and **expect it to fail**:

```bash
ssh mini 'claude --bg "echo ok"'      # expect: Not logged in
```

This proves the test discriminates. An ssh session cannot reach the mini's login
keychain, so a pass here would mean the test is measuring something else — and after
Phase C there is no second chance to notice.

### B2 — reseed

```bash
cd ~/SourceRoot/dotfiles-private && git pull    # the seed reads the LOCAL refs file
cd ~/SourceRoot/dotfiles && make secrets-seed   # biometric, one pass
```

The `git pull` is not optional.

### B3 — acceptance

```bash
ssh mini 'claude --bg "echo ok"'
ssh mini 'claude auth status'
```

**Must report `loggedIn: true`, `subscriptionType: max`.** Not `Not logged in`, and
not any other `subscriptionType`.

Belt and braces — the heartbeat asserts the same thing every 5 minutes:

```bash
ssh mini 'cd SourceRoot/dotfiles && make devhost-health-check'   # expect: claude auth ok (max)
```

### B4 — only after B3 passes

Drop the herdr-pane indirection in `scripts/remote-dev.sh` `cmd_bg`. It exists solely
because `ssh mini 'claude --bg …'` could not reach the keychain; once B3 passes, `rd
bg` can spawn the daemon directly over ssh instead of driving a throwaway herdr
workspace. **Deliberately left undone on the mini** — it is gated on this test, and
the test could not run there.

---

## Phase C — WP5 + WP6

**Do not start until B3 passed.** Automatic login does not unlock the login keychain;
that is the entire reason Phase B exists.

### C1 — WP5, power-on layer (MacBook, sudo)

Currently `autorestart 0` / `Automatic Restart on Power Loss: No` — mains returns and
the machine stays dark. This is a prerequisite for every option, not just this one.

```bash
sudo pmset -a autorestart 1 && sudo pmset -a autorestartatconnect 1
sudo pmset -a powernap 0
```

Leave alone: `womp 1`, `tcpkeepalive 1`, `ttyskeepawake 1`, `sleep 0`.

Acceptance — check this, not `pmset -g custom`:

```bash
ssh mini "system_profiler SPPowerDataType | grep 'Power Loss'"   # expect: Yes
```

### C2 — WP6, at the mini, physically

1. `sudo fdesetup disable` — interactive volume-owner prompt, cannot be scripted.
   `jkrumm` has a Secure Token and is a volume owner, so it succeeds. On Apple
   Silicon this is a Secure Enclave key re-wrap, not a decryption pass over 672 GB:
   effectively instantaneous, no data loss, disk stays hardware-encrypted.
2. `sudo sysadminctl -autologin set -userName jkrumm` — the supported mechanism. Do
   **not** hand-write `/etc/kcpassword`.
3. Decide the three console-security settings explicitly rather than inheriting
   undeclared defaults: `askForPassword`; Screen Sharing → "only these users →
   jkrumm"; clear the legacy `/Library/Preferences/com.apple.VNCSettings.txt`.
4. Re-check the ACL's `dst` for `:5900` is not `tag:mac`-wide.

**Rollback:** `sudo fdesetup enable` + `sudo sysadminctl -autologin delete`.
Re-enabling runs a real encryption pass and takes time — the asymmetry is expected.

### C3 — also while the screen is still on

- **L3.2, the logout test.** A real **logout**, not a reboot. Then from here,
  `tailscale ping mini` and `ssh mini` must both answer while the mini sits at the
  login window. Worth minutes even with FileVault coming off: it is the only thing
  that establishes whether Screen Sharing answers there, which is the fallback if
  FileVault ever goes back on.
- **Join the new LAN's Wi-Fi**, and turn off Private Wi-Fi Address for that SSID
  (System Settings → Wi-Fi; no CLI exists). This cannot be done headlessly and it is
  the **only** failover if the new wired path is bad. With no screen, a dead wired
  link is total loss of access.
- **WP8 remnant, sudo:** move aside the dead RadioSilence LaunchAgent plist. The
  extension itself is already gone (`[terminated waiting to uninstall on reboot]`),
  so the shutdown finishes it; this is just the stub launchd would keep failing on.
  ```bash
  sudo mkdir -p /Library/LaunchAgents/.disabled-20260731
  sudo mv /Library/LaunchAgents/com.radiosilenceapp.agent.plist /Library/LaunchAgents/.disabled-20260731/
  ```
  L2.4 and L2.5 in the checklist list the other system-domain plists to move with it.

---

## Phase D — power-cycle, still with the screen on

```bash
ssh mini 'cd SourceRoot/dotfiles && make colima-stop'    # a dirty Lima image is what WP7 works around
```

Then shut down from the Apple menu — not a pulled plug — and **power-cycle at the
wall**. That is the real test of WP5 + WP6 together: mains returns, and the machine
must come back to a live session on its own.

---

## Phase E — verify from here, with nobody touching the mini

Within ~10 minutes of the power-cycle, all of these with no human intervention:

```bash
ssh mini                                        # reachable
ssh mini 'claude auth status'                   # loggedIn true, subscriptionType max
ssh mini 'claude agents --json'                 # agents listed, max billing
ssh mini 'herdr session list'
ssh mini 'docker ps'                            # nine containers
ssh mini '/usr/local/bin/obsidian version'
ssh mini 'cd SourceRoot/dotfiles && make devhost-health-check'   # 13 components green
make remote-dev-doctor                          # expect 10/10
open vnc://mini                                 # a desktop, not a login window
curl -sI https://argo.mini.jkrumm.com
```

The `vnc://mini` line is the one that proves WP6: a login window means auto-login did
not take.

---

## Phase F — detach

Only after Phase E is clean **and** WP1 (Phase 0) is done. Pull the monitor, keyboard
and mouse; leave the HDMI dummy plug in if one is fitted. Power-cycle at the wall once
more as final proof, then re-run Phase E.

---

## At the new location

1. **DHCP reservation** for `5c:e9:1e:ec:5a:6e` on the new router.
2. `make remote-dev-doctor`
3. `ssh mini 'cd SourceRoot/dotfiles && make devhost-health-check'`
4. `ssh mini 'ifconfig en0 | grep media'` — was negotiating `100baseTX` on a 1 Gb/s
   NIC with clean error counters. A new cable may or may not fix it.

**The `.mini.jkrumm.com` dev doors and the `health.$DEV_DOMAIN` A record are pinned to
the tailnet IP, not the LAN IP**, so a LAN change does not move them. If they break
after the move, the cause is Tailscale re-keying, not DHCP — `check_dev_vhosts` in the
heartbeat asserts the drift directly.

---

## Decisions already taken — do not re-litigate

- **FileVault OFF + auto-login.** Reversed from an earlier "keep FileVault" call. The
  deciding fact: pre-boot SSH unlock leaves macOS at the *login window*, so all 15
  `gui/501` services stay down. Unlock is not login, and no remote-access trick makes
  that path automatic. Full reasoning in `mini-headless.md` §3b.
- **No UPS** (2026-07-31, owner). WP16 is closed, not deferred. The open question it
  turned on — whether `pmset autorestart` covers a UPS-triggered *graceful* shutdown,
  which is a deliberate off rather than a power failure — is now moot and needs no
  test.
- **Apps are stopped from booting, never uninstalled.** The IU work stack and its four
  containers are untouched.
