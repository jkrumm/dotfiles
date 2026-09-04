# Collie — the phone control surface

Condensed reference lives in `CLAUDE.md` → "Collie". This is the full rationale.

[Collie](https://github.com/AltanS/collie) is a loopback-bound Bun bridge + PWA
that mirrors the herd on a phone: open a URL, see which agent is blocked, type
a reply. Third-party, installed and **commit-pinned** by `make collie-setup` —
`COLLIE_REF`/`COLLIE_VERSION` in the Makefile — a commit, not a tag, because
tags move and `plugin install` re-clones and rebuilds the repo every time.
Since herdr-notes was retired it is the **only** pinned plugin left. Upgrading
is a reviewed diff of that pin, driven by `make collie-upgrade`; there is no
`plugin update`. Collie was chosen over granting the phone raw ssh: no port-22
grant, no SSH key on a device that can be lost or stolen.

**It is remote shell access by design, not "just a web UI".** One bridge call
types arbitrary keystrokes into a live pane — Collie's own README says to
treat the URL like a root login, and that framing should not get softened by
how it looks (a phone-friendly PWA). Granting it is granting a shell.

**The real gate is the ACL, not `COLLIE_TRUSTED_USER`.** Every node on this
tailnet is tagged (`tag:mac`, `tag:phone`, `tag:client`, …), so `tailscale
serve` has no human login to inject into `Tailscale-User-Login` — the
trusted-user check cannot tell our own devices apart from each other. That is
why the `.env` leaves `COLLIE_TRUSTED_USER` unset and the grant is scoped to
`tag:phone` specifically. **`tag:client` (the two TVs and the tablet) must
never be granted** — a television driving coding agents is not a theoretical
failure mode once the check itself can't discriminate.

The `.env` (written once by hand, not templated — `make collie-setup` never
touches it) carries four settings, each closing a specific gap:
- `COLLIE_MULTI_SESSION=off` — the default `on` fronts **every** named herdr
  session through one URL; this pins the bridge to the primary session only.
- `COLLIE_PUBLIC_HOSTS=mini.<tailnet>.ts.net:8788,mini.<tailnet>.ts.net` — defeats
  DNS rebinding, and **both entries are required**. `isHostAllowed`
  (`bridge/server.ts`) matches the full `Host` header by exact string, and the
  browser sends the ported host once the tailnet front door isn't on 443 — so
  the bare name alone 403s every phone request while every loopback check still
  passes clean. Verified matrix: `<name>:8788` → 200, bare `<name>` → 200,
  `evil.example.com` → 403, `<name>:9999` → 403.
- `COLLIE_SKIP_SERVE=1` — **mandatory**, not a preference. `collie-ctl.sh`
  publishes itself imperatively (`tailscale serve --bg 8787`), but this repo
  owns serve as *declared* state (`docs/remote-dev.md` → *Tailnet ACL and serve*)
  and
  `make tailscale-serve` runs `tailscale serve reset` first — an imperative
  binding is silently wiped on the next convergence. Collie stays
  loopback-only; the front door is the row in
  `dotfiles-private/tailscale-serve.mini.conf`
  (`8788  http://127.0.0.1:8787  no`). **Never funnel it.**
  The tailnet port is **8788, not tailscale serve's default 443**: on 443 the
  ACL grant would have to name the default port every future serve row lands on
  unless it says otherwise, silently sharing one grant with whatever gets
  published next — a dedicated port keeps the grant meaning exactly one
  service, permanently (same lesson as rb's dedicated `tcp:7730` grant). It
  also sits outside `7700-7799`, already granted `tag:mac → tag:mac` for dev
  servers, so reusing that range would hand collie to the work MacBook through
  an unrelated rule. An additive single-device tag (the `tag:iu-dashboard-funnel`
  pattern) was considered to narrow the grant's `dst` from `tag:mac` to the mini
  alone, and rejected: it requires re-tagging the device, and with a
  collie-only port nothing listens on 8788 on the work MacBook anyway. The
  bridge itself is still bound to loopback `127.0.0.1:8787` — only the
  `tailscale serve` front door moved.
- `COLLIE_HOST=127.0.0.1` — no interface binding beyond loopback; `serve`
  terminates TLS on the tailnet and proxies in.

**Supervision is upstream's**: `collie-ctl.sh start` writes
`~/Library/LaunchAgents/herdr.collie.plist` itself (`RunAtLoad` +
`KeepAlive {SuccessfulExit: false}` + `ThrottleInterval 5`), so this repo ships no
plist template of its own — two `RunAtLoad` + `KeepAlive` agents on port 8787 is
a fight neither wins cleanly, and upstream's `start` clears only its own pidfile
tier, so it cannot free the port from a label it has never heard of.
`make collie-setup` boots any legacy label out before calling `start`; that
migration is idempotent and self-deleting.

It is a **LaunchAgent, so it starts at login, not at boot** — and a Mac
administered purely over SSH has no `gui/<uid>` to bootstrap into, so upstream
degrades to the unsupervised tier with a warning instead of failing. That tier
passes every liveness probe and dies on the next reboot, which is precisely the
gap this whole section exists to close, so `collie-setup` asserts the plist
exists *and* the label is loaded, and fails otherwise. The mini clears this only
because it auto-logs-in (`docs/remote-dev.md` → *Unattended boot posture*) — that is what makes
"at login" equivalent to "at boot" here, and it is not true of a Mac without it.

Two upstream properties make that safe. PATH: `collie-ctl` resolves Bun from its
install locations rather than `PATH` alone, which matters because a
herdr-server-spawned command does not inherit Homebrew's PATH. And the `.env`:
upstream's plist execs `collie-ctl.sh _exec-bridge` rather than `bun`, and the
script sources the `.env` at top level (`set -a; . "$CONFIG_DIR/.env"; set +a`).

**Whatever starts it must source the `.env`.** This is the invariant, and it
outlives whoever owns the plist. The bridge reads `process.env` only
(`bridge/config.ts`) and never parses `.env` itself — on Linux systemd feeds it
in with `EnvironmentFile=-`, and launchd has no equivalent. Any start path that
reaches `bun` without sourcing it first brings the bridge up with
`COLLIE_PUBLIC_HOSTS`, `COLLIE_MULTI_SESSION` and `COLLIE_SKIP_SERVE` **all
unset** — every hardening setting above quietly off, DNS-rebinding guard
included — while `launchctl list` shows status 0 and the UI works perfectly.
Upstream holds that invariant today and is one refactor away from silently
inverting it, which is why the check is **behavioural**: after any change to how
the bridge is started or to the `.env`, a spoofed `Host` header must still return
403 **on `/api/snapshot`**. The path is load-bearing — the guard fires on API
routes only, and the CSP-locked SPA shell at `/` answers 200 to any Host, so a
pathless probe reports the guard broken when it is fine. `make collie-setup`
**fails** on anything but 403, so re-run that assertion, not just
`launchctl list`.

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only (gated on the `cache` backend marker): install/refresh the pinned plugin, migrate off the legacy agent, `collie-ctl.sh start`, then assert liveness + the rebind guard + that launchd actually supervises it |
| `make collie-upgrade` | Dev-host only: resolve the newest release tag, print its changelog + diffstat + a scope verdict, and on `y` bump the pin, reinstall, assert, commit |
| `make collie-status` | Read-only: LaunchAgent state, bridge health, rebind guard, `tailscale serve status` |
| `make collie-teardown` | Boot out both labels (current + legacy), uninstall the plugin — deliberately **not** `collie-ctl.sh uninstall`, which attempts a `tailscale serve` teardown even under `COLLIE_SKIP_SERVE=1`; serve is declared state and no upstream script gets to mutate it |

**Upgrading is still a reviewed diff — `make collie-upgrade` just removes the
eleven mechanical steps around it.** There is no `plugin update` (herdr's docs:
"reinstall from GitHub to refresh"), and upstream's own `collie-ctl.sh update`
is deliberately unused here: it pulls **branch head**, which discards the pin and
can land pre-release commits.

**The scope verdict it prints is decision support, not a safety boundary — do
not let it grow into an auto-applier.** It answers "did anything outside `web/`
move?", which catches a *bridge or hardening* change worth reading closely. It
does not make a UI-only release safe: the PWA **is** the control surface, so
malicious `web/` code reads the snapshot and sends keys exactly as well as
malicious `bridge/` code would. `bun.lock` is excluded from the safe set for the
same reason — a changed lockfile is a changed dependency. What makes a bad
release survivable is the rollback: `collie-setup`'s spoofed-Host assertion runs
after the install, and a failure restores the previous pin and reinstalls it.

It refuses to run unattended (no TTY and no `COLLIE_UPGRADE_YES=1` → exit 1) and
refuses on a dirty `Makefile`, since it commits that file. It commits locally and
never pushes.

**Monitoring is opt-in, and wiring it is scripted end to end.** Collie reports
to its own Kuma monitor, `MacMini Collie - Push` (id=205, declared in
`homelab/uptime-kuma/monitors.yaml`), pushed by the existing
`com.jkrumm.devhost-health` LaunchAgent — see `docs/devhost-health.md`
for why it is a separate monitor rather than a composite component. On a fresh machine:

1. `make uk-sync` from `homelab` — creates the monitor if absent, no browser.
2. Fetch its `pushToken` and write `https://uptime.jkrumm.com/api/push/<token>`
   into `~/.config/uptime-kuma/collie-push-url`, `chmod 600` (the
   `uptime-kuma-api` snippet is in `docs/devhost-health.md`).

Until step 2 the collie push is skipped silently, which is deliberate: a machine
that never ran `collie-setup` has no collie and must not fail the heartbeat.

