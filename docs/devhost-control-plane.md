# Dev-host control plane — plan

Status: proposed, nothing built. Written 2026-07-31.

Goal: run and watch dev servers on the mini from the browser and from a CLI —
start/stop, live logs, status — then grow into Docker and compose management,
and eventually absorb `linewatch`. Lands in its **own repo**, not dotfiles.

Grounded against the live machine on 2026-07-31: 18 `.test` doors in
`config/Caddyfile`, 9 running containers, 3 of 24 SourceRoot repos with a
`make dev` target.

---

## 1. Verdict

Process supervision and log streaming are a weekend. The blocker is that the
registry this would build on **does not model the thing being controlled**.
`config/Caddyfile` is keyed by *door* (name → port). Starting a dev server is
keyed by *repo*. Those are not 1:1 — 18 doors resolve to 12 units — and the
mapping exists nowhere today.

Two consequences that shape everything below:

- **Docker is not a phase 2.** Three of the 12 units are already containers
  (`rb`, `linewatch`, `hyperdx`), sitting in the registry pretending to be dev
  apps. A `door → port` data model gets rewritten the moment containers are
  added properly. Model it once: a door is served by a **unit**; a unit is
  either a repo process or a compose service.
- **Two of those containers are always-on services, not dev servers.** Stopping
  `rb` or `linewatch` is an outage, not a restart. The UI must not offer one
  button for both classes.

---

## 2. The unit model

The missing artifact. Everything else is downstream of getting this table into
a tracked file.

| Door(s) | Port(s) | Unit | Kind | Note |
|-|-|-|-|-|
| `rollhook`, `rollhook-marketing`, `rollhook-dashboard` | 7700–7702 | repo `rollhook` | ephemeral | one `bun run --parallel dev:*` → 3 doors |
| `sideclaw` | 7705 | repo `sideclaw` | **both** | `make dev` exists, but `com.jkrumm.sideclaw` also runs it always-on — see §7 |
| `hyperdx` | 7707 | compose | ephemeral | not currently running |
| `basalt-playground`, `basalt` | 7710, 7711 | repo `basalt-ui` | ephemeral | name mismatch, 2 doors |
| `argo` | 7715 | repo `argo` | ephemeral | dev script wraps `secrets-run`, two env files |
| `image-gen` | 7716 | repo `image-gen` | ephemeral | has `make dev` |
| `photoflow` | 7717 | — | **orphan** | no repo on this host; MacBook-only |
| `fpp`, `fpp-server`, `fpp-analytics`, `fpp-logdy` | 7720–7723 | repo `free-planning-poker` | ephemeral | name mismatch, 4 doors |
| `modelpick` | 7727 | repo `modelpick` | ephemeral | has `make dev` |
| `jkrumm` | 7728 | repo `jkrumm.com` | ephemeral | name mismatch |
| `rb` | 4050 | compose `rb` | **always-on** | running; Tailscale-only service |
| `linewatch` | 7731 | compose `linewatch` | **always-on** | running; monitoring, stopping it punches a hole in its own record |

Four distinct failures a naive `door == app` model produces: the three-door
single-process repo, four name mismatches, an orphan door with no local unit,
and always-on containers offered a "stop" button next to ephemeral dev servers.

**Where the file lives.** Tendency: in **dotfiles**, next to
`~/.config/caddy-tailnet.ports`, which it resembles — an annotation layer over
the Caddyfile registry. The daemon reads it; dotfiles owns it, because the
Caddyfile it annotates is owned here and both should move in one reviewed diff.

**What it must NOT do:** restate the registry. Same rule the ports file already
learned the hard way — two lists drift, and the registry is
`config/Caddyfile`. The unit file records repo, kind, and exceptions. Doors are
derived.

---

## 3. `make dev` is the contract

Survey of the 24 repos on the mini:

| Shape | Count | Examples |
|-|-|-|
| `make dev` | 3 | `image-gen`, `modelpick`, `sideclaw` |
| `package.json` `dev` script | ~12 | `argo`, `rollhook`, `research-gateway` |
| Makefile, no `dev` target | ~9 | `linewatch` (`make up`), `homelab`, `vps` |

The commands all exist. They are just not addressable by a common name, and
several already wrap `secrets-run` (`argo`, `audio-gateway`,
`research-gateway`), so the launcher cannot be a naive `bun dev`.

Mandating `make dev` is right and already the house rule — `docker-makefile.md`
exists because Makefiles encode secret injection, ordering and flags. It also
absorbs the compose units for free, which a `package.json` convention cannot:
`linewatch`'s `make dev` is just `make up`.

**Reject the runtime-LLM idea.** Having an agent infer how to start a server is
nondeterministic at exactly the moment determinism is wanted, requires model
access to boot a dev server, and the answer would be cached anyway — so cache
it in git, as a reviewed `make dev` target.

Keep the agent as a **one-time authoring aid**: repo has no `make dev` → scaffold
one from `package.json` and the Caddyfile ports, present it as a diff. Authoring
path, never the execution path. An app whose repo refuses to grow a `make dev`
does not become unlaunchable-and-silent; the page says "no `make dev`", which is
the same honesty as the existing 403 explanation.

---

## 4. What the daemon replaces

`scripts/caddy-tailnet.sh` is 1185 lines of bash generating static HTML from a
heredoc. That is at its limit, and it is why the `tailscale serve` table on the
landing page is a snapshot that goes stale until `make caddy-tailnet` re-runs.

**The daemon serves the page; Caddy keeps the routes.**

| Layer | Stays | Moves |
|-|-|-|
| Caddy site block, `host` matchers, wildcard cert | ✓ | |
| `/_up/<name>` probes | ✓ — zero-dependency, same argument that keeps the port doors as a fallback | |
| Landing page HTML | | → daemon (`handle {}` becomes `reverse_proxy localhost:<daemon>` instead of `file_server`) |
| Serve-rows table | | → daemon, read live instead of at generation time |
| New: `handle /_api/*` | | → daemon, alongside `/_up/*` |

Caddy config generation stays static — routes must exist in Caddy. Only the
*page* becomes dynamic.

**Phase 1 therefore adds zero new tailnet surface**: same `:443`, same wildcard
cert, same `tag:devhost → tcp:443` grant, no new `tailscale serve` row, no ACL
change. Same-origin by construction, exactly like `/_up/`.

**Not herdr.** herdr's unit is a human's interactive pane. A dev server parked
in one dies when a pane nobody remembered is closed, its scrollback is a capped
terminal buffer that cannot be queried, and a herdr crash restores the layout
while losing every process in it. Spawn detached, log to files.

**Native, under launchd — not in Docker.** It spawns host processes and will
want the Docker socket; a control plane inside a container that can stop its
siblings including itself is a worse shape than a native daemon. Same split
`linewatch` already made for its ICMP collector.

Two traps already paid for elsewhere on this machine: a launchd-spawned process
inherits neither Homebrew's PATH nor `~/.local/bin` (the collie `bun not found`
failure), and half the `dev` scripts shell `secrets-run`, which lives in the
latter. Pin PATH explicitly in the plist.

---

## 5. Posture: this is collie-class

Today the landing page is generated static HTML — read-only, no daemon. The
moment it can start a process it becomes remote code execution over the tailnet,
and it should be documented in the same terms `collie` is: granting it is
granting a shell.

The population does not change — `tag:mac` and `tag:tablet` already reach every
dev door on 443, and `tag:client` (the two TVs) does not. The *capability* for
that population does. Name it explicitly rather than letting it arrive as a side
effect of a nice button.

Concrete rules, inherited from collie's hard-won list:
- Bind the daemon to `127.0.0.1` only. Caddy is the sole front door.
- Health checks assert **behaviour, not liveness** — collie's DNS-rebind guard
  was silently off while `launchctl list` reported status 0 and the UI worked.
- No `tailscale serve` row of its own. Anything imperative gets wiped by
  `make tailscale-serve`'s `reset`.

---

## 6. Logs and events — a deliberate split

| Data | Store | Why |
|-|-|-|
| Log **lines** | per-unit files under `~/Library/Logs/devhost/`, rotated, tailed over SSE | high-volume, ANSI-coloured, worthless after a day |
| Log **events** (started, exited, exit code, crash, restart, duration) | SQLite | the part worth keeping — and the part that makes this a *watch* product rather than a launcher |

Not `/tmp`. WP9 of `docs/mini-headless.md` is the cautionary tale: macOS
periodic cleanup unlinked sideclaw's SQLite job DB and both its log files while
the process held the fds open, so its state exists only in one process's address
space and its logs go to an inode with no name.

**The CLI ships first.** `devctl status|start|stop|logs <unit>` over the same
HTTP API. The agents already living on this machine benefit immediately; the web
UI is the second consumer of the API, not the first. Building the UI first would
let the API shape itself around one caller.

---

## 7. Phases

**Phase 1 — lean.** Unit file, daemon, CLI, start/stop/logs for ephemeral repo
units. Docker **read-only** in the same pass (list containers, map them to
units and doors) because the model needs the concept from day one — container
start/stop can wait. No linewatch merge. The landing page moves to the daemon.

**Phase 2 — containers.** Start/stop for ephemeral compose units. Requires an
explicit boundary first: `docker ps` today also shows `dashboard-ui`,
`dashboard-api`, `idss-mysql`, `idss-valkey` and `prometheus-vpn` — the IU work
stack, outside the `.test` registry, and the `:8443` Funnel depends on
`dashboard-ui`. Decide whether the control plane can see them at all before it
can stop them.

**Phase 3 — merge, maybe.** See §8.

**Resolve before phase 1 code:** `sideclaw` occupies both classes. Door 7705
points at port 7705 whether that is the always-on `com.jkrumm.sideclaw`
LaunchAgent or a `make dev` in the repo, and starting the second while the first
holds the port fails in a way the UI will render as a mystery. Either the unit
file declares `sideclaw` always-on and the dev path is out of scope, or the
daemon learns to detect "port already held by a launchd job" and says so.

---

## 8. linewatch

Merging is coherent eventually — both are "facts about this machine over time",
and `linewatch` is already the closest existing thing to the daemon being
proposed: Bun + SQLite + a bearer token in a local file (deliberately not an
`op://` ref, so monitoring survives a stale secrets cache) + a web UI + a native
launchd half where the container cannot reach.

Do not merge on aesthetics. Merge when there is a query someone actually wants
to run across both — "did that dev server die at the same moment the line
dropped?" is the shape that would justify it. Until then, two services.

Reuse the shape immediately regardless: local token file over `op://`, native
where the host boundary demands it, containerised where it does not.

---

## 9. Is it its own product?

Probably, eventually — nothing quite covers this combination. Not yet, and not
as a design constraint: building for machines that do not exist adds
configuration surface with no second user to validate it. What would make it
good is that it is shaped by one real machine with a genuinely awkward setup —
headless, Colima, tailnet-only, two 1Password accounts, a secrets cache.

Extract when a second machine actually wants it. The MacBook is the honest test
case, and it holds no project repos, so it would exercise the orphan-door path
and almost nothing else.

---

## 10. Open questions

| Question | Tendency |
|-|-|
| Unit file in dotfiles or in the new repo? | **dotfiles** — it annotates `config/Caddyfile`, and the two should move in one diff. |
| Is `make dev` a hard requirement? | **Yes.** The alternative is not "the agent figures it out", it is "some apps cannot be started from the UI" — which is fine as long as the page says so. |
| Repo name | Undecided. `devhost` is descriptive; the eventual linewatch merge argues for something that covers both. |
| Does the daemon own `/_up/` too? | **No.** Leave the probes in Caddy — zero-dependency, and a daemon outage should not blank the status column that would diagnose it. |
| Auth on `/_api/*` beyond the ACL? | Open. The tailnet grant is the real gate (collie's lesson: every node is tagged, so there is no user identity to check). A token adds defence-in-depth and costs a header. |
| Restart-on-crash for ephemeral units? | **No.** A dev server that crashed should stay crashed and visible. Auto-restart hides the compile error. |

---

## 11. Deliberately not doing

- **Not building on herdr.** §4.
- **Not running the control plane in Docker.** §4.
- **Not inferring dev commands at runtime.** §3.
- **Not giving it a `tailscale serve` row.** It rides the existing `:443`
  wildcard, and an imperative binding is wiped by `make tailscale-serve`.
- **Not offering stop for always-on units in phase 1.** `rb` and `linewatch`
  are services; a stop button next to a dev server's is a mislabelled control.
- **Not touching the IU work containers** until the boundary in §7 is decided.
- **Not moving the Caddy config generation into the daemon.** Routes must exist
  in Caddy before a request arrives; only the page is dynamic.
