# Homebrew — Brewfile as supply-chain audit trail, and why auto-upgrade stays off

Condensed reference lives in `CLAUDE.md` → "Homebrew". This is the full rationale.

## Brewfile is the source of truth, not the machine

All brew-managed packages are declared in **`Brewfile`** (repo root) — the single
source of truth (full machine manifest: taps + formulae + casks). `make setup`
installs from it in one `brew bundle install` step (`_setup-packages`), so the
per-tool `brew install` lines are gone from the Makefile; each `_setup-*` step now
only *configures* (links config, runs services, wires the VM). **npm-global and uv
tools stay Makefile-managed** (fallow, litellm, etc.) — they need Node/uv on PATH,
not ready that early in bootstrap — so the Brewfile is deliberately brew-native only.

Keep it honest (the Brewfile's **git history is the supply-chain audit trail** —
nothing joins the manifest without a reviewed diff):

- `make brew-check` — verify machine == Brewfile (read-only).
- `make brew-diff` — list installed-but-undeclared packages (dry-run).
- `make brew-dump` — regenerate from machine (brew-native only; preserves the header), then **review the git diff** before committing.

Adding a brew package: `brew install X` → `make brew-dump` → review diff → commit
(or edit `Brewfile` → `brew bundle install`). Source of truth is the **file**, not
the machine.

**Hardening** lives in `config/zsh/brew.zsh`: `HOMEBREW_REQUIRE_TAP_TRUST=1`
(refuse untrusted third-party taps). `_setup-packages` auto-runs `brew trust` on exactly
the taps the Brewfile declares **before** `brew bundle` — otherwise a declared-but-untrusted
tap makes bundle refuse and abort the whole manifest on a fresh machine (this once silently
skipped colima/docker). Self-maintaining: trust follows the vetted manifest, no hardcoded list.
Other hardening: `HOMEBREW_NO_INSECURE_REDIRECT=1`, `HOMEBREW_NO_ANALYTICS=1` (also `brew analytics
off`). Auto-*update* (metadata refresh) stays on.

## Upgrading — `make brew-upgrade`

Auto-*upgrade* (unattended `brew upgrade`) stays off, but **not for the reason
this file claimed for months**. It said "auto-upgrade is the npm-style risk",
which is a dependency-hygiene rule applied to the wrong ecosystem: a
homebrew/core formula is a reviewed PR built into a bottle by Homebrew's own
CI, not a maintainer publishing a tarball straight to a registry with a
`postinstall` hook. Nothing on either machine has ever come from outside
homebrew/core, homebrew/cask, or the four vetted taps. So the cooldown
argument, which is the whole defence in npm, buys almost nothing here — while
sitting on unpatched `libssh2`/`libarchive`/`sqlite` point releases costs
something real.

**The actual hazard is silent config revert, and it is three packages.**
Each has local machinery bolted on top that an upgrade destroys with no error:

| Package | What an upgrade breaks | Visible after |
|-|-|-|
| `caddy` | replaces the xcaddy-built binary; `dns.providers.cloudflare` vanishes | ~60 days, when the wildcard cert fails to *renew* |
| `mosh` | ALF stores mosh-server's *resolved* Cellar path, so the upgrade un-allows it | next inbound `dev` — ssh handshakes, then every datagram drops |
| `colima` | regenerates the plist, restoring the inverted `KeepAlive {SuccessfulExit=true}` and the direct `colima start -f` | only after a *dirty* shutdown, when the failed start is never retried — i.e. the power cut this whole setup exists to survive |

**`colima` is asserted but deliberately not pinned**, unlike the other two. Pinning
caddy and mosh costs nothing — they are stable and their local machinery is
rebuilt by a named target. colima is the Docker runtime and holds the VM; pinning
it means sitting on an unpatched hypervisor to protect a two-key plist that
`make colima-restart` re-converges anyway. So it gets the post-upgrade assertion
and a 5-minute health check instead, which is the same trade with the failure
made loud rather than prevented.

**`brew pin` is the enforcement, not a hold list some script knows about.**
`brew upgrade` skips pinned formulae and refuses a named `brew upgrade caddy`
outright, so the guard holds for a bare command typed by hand six months from
now. `_setup-packages` converges the pins on every `make setup`, so a fresh
machine is protected before `caddy-dns-build` has run even once.

| Command | Does |
|-|-|
| `make brew-upgrade` | Converge pins, upgrade outdated **homebrew/core formulae**, then assert all three invariants |
| `make brew-upgrade-dry` | True no-op preview — reports what *would* be pinned/upgraded and touches nothing |

Casks and third-party-tap formulae are **reported, never auto-upgraded** —
casks are vendor binaries (Homebrew ships the metadata, the bits come from the
vendor), which is where the release-age cooldown genuinely applies. Those go
through `/upgrade-deps`. A held package that is outdated prints its own
deliberate four-step follow-up (`brew unpin X && brew upgrade X && make <fixup>
&& brew pin X`) rather than being silently dropped.

**That cask exclusion is a preference, not a guarantee — unlike the caddy/mosh
pins.** A bare `brew upgrade` upgrades casks too (it says so: *"Homebrew will
now attempt to upgrade casks with `auto_updates true`"*), and casks are
deliberately left unpinned. Pinning them all would mean hand-maintaining a list
that silently stops receiving security updates — a worse trade than a soft
preference honoured by the command you normally reach for. The two formulae are
pinned because *their* failure mode is silent config revert, which no amount of
care at the keyboard catches after the fact.

**It asserts rather than assumes the pins protected anything** — a dependency
upgrade can relink a dependent, so after upgrading it re-checks the caddy module
and the ALF allowlist directly (dev-host-gated on the `cache` backend marker,
same gate `caddy-dns-build` uses) and re-checks that every held package is still
pinned. `--dry-run` deliberately does *not* converge pins: a `-dry` target that
mutates machine state is the surprise `makefile-conventions.md` exists to
prevent, and it is the command you reach for precisely because you are not ready
to touch anything.
