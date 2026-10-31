# Collie — the phone control surface

Condensed reference lives in `AGENTS.md` → "Collie". This is the full rationale.

[Collie](https://github.com/AltanS/collie) is a loopback-bound Bun bridge + PWA
that mirrors the herd on a phone: open a URL, see which agent is blocked, type
a reply. Third-party, built and **commit-pinned** by `make collie-setup` —
`COLLIE_REF`/`COLLIE_VERSION` in the Makefile — a commit, not a tag, because
tags move and the setup compiles whatever the pin resolves to. Upgrading is a
reviewed diff of that pin, driven by `make collie-upgrade`. Collie was chosen
over granting the phone raw ssh: no port-22 grant, no SSH key on a device that
can be lost or stolen.

**It runs standalone on herdr-core, not as a herdr plugin** (Wave 4, upstream
1.25.0+, `COLLIE_MUX=herdr-core`, tested upstream on hc 0.1.14, proven here on
0.1.15). The bridge is upstream's compiled `bin/collie _exec-bridge` under
our own LaunchAgent `com.jkrumm.collie`. It reaches the core **only through the
core's socket** (`$XDG_STATE_HOME/herdr-core/<session>/<session>.sock`, the same
file `hc` dials; `HC_SESSION` / `HC_SOCKET` in the plist select another) and
never runs `hc`, so it cannot start a core: **launchd owns the core**, and a
stopped core reads as `bridge: disconnected` until `com.jkrumm.herdr-core` is
back, after which the bridge reconnects by itself. `make collie-setup` refuses
while the core's LaunchAgent is not running.

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

The `.env` lives at `~/.config/collie/.env` (mode 600, never templated). It was
written once by hand; `make collie-setup` copies it once from the classic plugin's
config dir if the new one is missing, and then touches exactly one line:
`COLLIE_MUX=herdr-core`. It also **refuses** to install when `COLLIE_SKIP_SERVE=1`,
`COLLIE_HOST=127.0.0.1` or a non-empty `COLLIE_PUBLIC_HOSTS` is missing. The
settings, each closing a specific gap:
- `COLLIE_MUX=herdr-core` — which terminal host the bridge drives. Named
  explicitly, because with it unset upstream picks by what it finds and could
  land on classic herdr, still installed until Wave 7. The plist repeats it, so
  an `.env` edit cannot move the bridge off the core.
- `COLLIE_MULTI_SESSION=off` — the core adapter drives exactly one session
  (`HC_SESSION`, default `default`); upstream's default `on` would front every
  named session through one URL.
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

**Supervision is ours**, and so is the plist: `scripts/com.jkrumm.collie.plist.template`
(`RunAtLoad` + `KeepAlive {SuccessfulExit: false}` + `ThrottleInterval 5`, log
`~/Library/Logs/collie.log`, rotated by `log-rotate` from the plist). We never run
upstream's `collie start`: it writes a unit of its own and publishes `tailscale
serve` imperatively. Until Wave 7, `make collie-setup` also boots out the classic
plugin's `herdr.collie` agent and uninstalls the plugin (idempotent; a no-op on a clean machine).

**The install is deliberately not a git checkout.** Upstream can update a git
checkout in place, from a paired phone (`POST /api/update` pulls the newest release
tag), which would walk past the commit pin. `collie-setup.sh` keeps a bare clone
cache, checks the pinned commit out into `~/.local/share/collie/<ref12>/`, builds it
(`bun run cli/main.ts build`, the fetched source building itself, not an older
binary), asserts `bin/collie version` is `<version>+<commit>`, and then **deletes
`.git`**. Upstream classifies a tree like that as `unknown/loose-binary` and declines
to update it. One directory per pinned commit; the previous one stays for a rollback,
older ones are pruned. The bridge keeps its state (paired devices, local credential)
in `~/.local/state/collie`, outside the build directories.

It is a **LaunchAgent, so it starts at login, not at boot** — and a Mac administered
purely over SSH has no `gui/<uid>` to bootstrap into, so `collie-setup` fails there
rather than degrading to an unsupervised process. The mini clears this only because it
auto-logs-in (`docs/remote-dev.md` → *Unattended boot posture*) — that is what makes
"at login" equivalent to "at boot" here, and it is not true of a Mac without it.

**Whatever starts it must get the `.env` in.** This is the invariant, and it outlives
whoever owns the plist. The plist carries paths only (it is world-readable, the `.env`
is mode 600 and can hold a push key); `_exec-bridge` parses the `.env` at launch via
`HERDR_PLUGIN_CONFIG_DIR` (upstream's variable name). Any start path that reaches the bridge without it brings it
up with `COLLIE_PUBLIC_HOSTS`, `COLLIE_SKIP_SERVE` and the rest **all unset** — every
hardening setting above quietly off, DNS-rebinding guard included — while `launchctl
list` shows status 0 and the UI works perfectly. That is why the check is
**behavioural** (`scripts/collie-check.sh`, run by `collie-setup` and `collie-status`):

1. `/api/health` answers, with the pinned `<version>+<commit>`.
2. `/` serves the SPA shell.
3. A spoofed `Host` on **`/api/snapshot`** returns 403. The path is load-bearing: the
   guard fires on API routes only, and the CSP-locked shell at `/` answers 200 to any
   Host, so a pathless probe reports a healthy guard as broken.
4. The bridge reaches the core: `/api/snapshot` with the host-local credential (the
   bridge's own `local-secret`, **read-only**, it cannot type) says `bridge: connected`
   and lists the core's terminals.

`make collie-setup` **fails** on any of them, so re-run that, not just `launchctl list`.
The check never calls `hc`: an `hc` call with no core running starts one.

**Every `/api` route needs a paired device** (upstream ADR 0086; only `/api/health` and
`POST /api/pair` are open). The code is minted on the host's terminal on purpose:
`make collie-pair`, then enter it in the phone's Settings. A phone refused after an
upgrade re-pairs the same way.

**What the core adapter does and does not do** (upstream, 1.25.x): the mirror is plain
text without colour; a send takes about six seconds (the core holds keys for ~3 s);
there is no focus, rename or worktree; History and Chat for a Claude pane need `collie
hooks install claude`, which is **not** installed here — it edits Claude's settings,
which this repo renders from a template, so it needs its own decision.

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only (gated on the `cache` backend marker): refuse unless the core's LaunchAgent runs, build the pinned commit, check `.env`, render + bootstrap `com.jkrumm.collie`, retire the classic plugin (until Wave 7), then run the behavioural check |
| `make collie-upgrade` | Dev-host only: resolve the newest release tag, print its changelog + diffstat + a scope verdict, and on `y` bump the pin, rebuild, assert, commit |
| `make collie-status` | Read-only: LaunchAgent state, installed build vs pin, the behavioural check, `tailscale serve status` |
| `make collie-pair` | Mint a one-time pairing code for a phone |
| `make collie-hc-proof` | Re-prove the pinned build against a **scratch** core (own session + LaunchAgent, torn down on exit): setup, list, read, type, "core gone: nothing starts one, the bridge reconnects". a few minutes, mostly the build; run it after a pin bump or a core bump |
| `make collie-teardown` | Boot out both labels (current + legacy), remove the checkouts and uninstall the plugin if still there — deliberately **not** `collie uninstall`, which attempts a `tailscale serve` teardown even under `COLLIE_SKIP_SERVE=1`; serve is declared state and no upstream script gets to mutate it. The `.env` and the paired devices stay |

**Upgrading is still a reviewed diff — `make collie-upgrade` just removes the
mechanical steps around it.** Upstream's own `collie update` and the phone's in-app
update are deliberately unusable here (see *not a git checkout* above): they pull the
newest release, which discards the pin.

**The scope verdict it prints is decision support, not a safety boundary — do
not let it grow into an auto-applier.** It answers "did anything outside `web/`
move?", which catches a *bridge or hardening* change worth reading closely. It
does not make a UI-only release safe: the PWA **is** the control surface, so
malicious `web/` code reads the snapshot and sends keys exactly as well as
malicious `bridge/` code would. `bun.lock` is excluded from the safe set for the
same reason — a changed lockfile is a changed dependency. What makes a bad
release survivable is the rollback: `collie-setup`'s behavioural check runs after the
install, and a failure restores the previous pin and rebuilds it.

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

