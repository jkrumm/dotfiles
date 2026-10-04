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
  `tag:mac` would expose the work MacBook. **That one port is the machine's entire
  public surface** — don't "clean up" the tag.
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
