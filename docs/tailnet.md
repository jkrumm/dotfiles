# Tailnet ACL and serve — as code

Both are **declared state in `dotfiles-private`** (an ACL is a security boundary,
a serve file an exposure map) with the tooling here, and both apply **from the
MacBook**: the API key is `op://Private/Tailscale`, which the mini's cache refuses
by design.

| Command | Does |
|-|-|
| `make tailscale-acl-diff` | **Always first** — a push overwrites the whole tailnet ACL |
| `make tailscale-acl-pull` | Fetch live **into** the file, staged through a temp file |
| `make tailscale-acl-push` | Validate + apply (prompts; `ACL_PUSH_YES=1` bypasses) |
| `make tailscale-serve` / `-check` | Converge / report drift against `tailscale-serve.<machine>.conf` |

- **Every listening port needs a grant and the failure is silent** — no refusal,
  no log line on either end, just a timeout. The clean door rides `tcp:443`;
  `tcp:7700-7799` covers dev servers that bind `0.0.0.0`.
- **Applying serve does `tailscale serve reset` first** — a device rename leaves
  bindings under the old name that no per-port `off` can address. Row column 4 is
  an optional human label the applier normalises away, so it cannot cause drift.
- Rows: `:7730` (rb) and `:8788` (Collie), tailnet-only; **`:8443` — Funnel,
  public internet**, the IU dashboard, gated by `tag:iu-dashboard-funnel`, an
  *additive single-device* tag because Funnel is a whole-device capability and
  `tag:mac` would expose the work MacBook; **`:10000` — Funnel, public internet**,
  Athena Teamchat (token-gated chat-api, same tag and grant). **Those two ports are
  the machine's entire public surface** — don't "clean up" the tag.
- **Tagging a device is console-only** and independent of pushing a grant — both
  are silently inert without the other. Verify the live filter with no API key
  from the mini: `tailscale debug netmap`, parsing `PacketFilter`.
- **`--accept-routes` is off on the mini** — imperative daemon state with nothing
  declaring it; re-check after any Tailscale reinstall or re-auth.
- **The mini and homelab are on different networks** and meet only over Tailscale
  — homelab is *not* a LAN jump host for the mini.
- The mini runs the **open-source `tailscaled` from Homebrew** (root LaunchDaemon,
  starts before login), never the macsys app; consumers resolve the CLI through
  `scripts/lib/tailscale-cli.sh` — a leftover app-bundle CLI answers with a stopped
  tunnel and a stale IP, a wrong answer rather than an error.

## Updates

`make tailscale-status` compares each daemon with the latest stable; `make tailscale-upgrade [HOST=homelab|vps|mini]`
(`scripts/tailscale-upgrade.sh`, from the MacBook) upgrades one node at a time and waits for the new daemon to answer on a
fresh connection. Measured 2026-11-06: 8 s (homelab), 11 s (VPS), 12 s (mini); containers, agents and the mini's Funnel and
serve config untouched. Restarting tailscaled ends every ssh session over it, so nothing depends on the session surviving:

| Machine | Install | How it updates |
|-|-|-|
| homelab, VPS | apt, `Check`+`Apply` auto-update on | apt runs in its own systemd unit, or a Tailscale SSH child dies mid-upgrade (upstream #21021: dpkg locked for days). Auto-update stays on, but starts about a week after a release and defers around activity: both sat a release behind four security bulletins, so the mini's daily drift check names a behind server |
| mini | Homebrew `tailscaled` as a system daemon, pinned in `brew-upgrade.sh` | Formula first (the old daemon keeps its inode), then a detached root watchdog restarts it and relinks the previous keg if it does not reach `Running` in 90 s. Refuses without a LAN path unless `FORCE=1`; the log is `~/Library/Logs/tailscale-upgrade.log` |
| MacBook, iPhone | App Store (`io.tailscale.ipn.macos`) | App Store only; `tailscale update` just opens it. The store can trail the stable feed |

The mini's LAN address answers from the MacBook at home (verified 2026-11-06), so at home it has a second door. Away, the
watchdog is the only net, and a person at the screen the last one.
