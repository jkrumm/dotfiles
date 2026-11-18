# host-agent

One small OpenTelemetry Collector per machine sends host metrics to the estate's ClickStack (the VPS) and gives every app on
the machine a loopback OTLP endpoint. It runs on the Mac mini (`host.name=mini`) and, once `make agent-setup` has run there,
on the MacBook (`host.name=macbook`). It is the Mac half of vps Issue 2055 (`vps/agent/`, the same ocb manifest). Beszel and
every sampler on the mini keep running: nothing is removed until the parity table below has been lived with.

| | |
|-|-|
| LaunchAgent | `com.jkrumm.host-agent`, KeepAlive, `ThrottleInterval` 10 s |
| Files | `agent/` (`manifest.yaml`, `config.yaml`, `host-agent-wrapper.sh`, the plist template), `scripts/host-agent-install.sh` |
| Binary | `~/.local/bin/host-agent`, built here, pinned by `HOST_AGENT_VERSION` and `OCB_VERSION` in the Makefile |
| Receiver | OTLP on **127.0.0.1:4416** (gRPC) and **127.0.0.1:4417** (HTTP), registered as `ports` in `config/mini/services.yaml`; the on-demand dev ClickStack publishes 4318 and 4319 |
| Exporter | `otlp_http` to the authed ClickStack endpoint (`op://mini/agent-workflows/OTEL_EXPORTER_OTLP_ENDPOINT`, key `op://vps/argo/HYPERDX_API_KEY_PROD` as the `authorization` header), `sending_queue` on disk under `~/.local/state/host-agent/queue`, retries never give up (every 5xx but 501 counts as retryable, see the patch below) |
| Logs | `~/Library/Logs/host-agent.{log,err}` (rotated by `log-rotate`, which derives its list from our plists) |
| Verbs | `make agent-setup` (build if the pin or manifest changed, render + load, then the status) · `make agent-status` (the doctor's host-agent section) · `make agent-uninstall` |

## What it does

- **Host metrics.** Every 30 s: `cpu` (`system.cpu.utilization`; the raw time series is off), `memory` (with utilization), `load`, `paging`
  (with utilization), `network` (`en*` only), `processes` (counts). Every 60 s: `disk` (`disk*` devices), `filesystem` (with utilization),
  `system` (uptime). Resource: `host.name`, `deployment.environment.name=prod`, `service.name=host-agent`, `service.namespace=infra`.
- **Filesystems.** `df` on the mini shows eleven mounts. Only two are real: `/System/Volumes/Data` (the user data volume; `/` is the sealed
  system volume and always the same) and the external volume under `/Volumes/`. Left out: the sealed system volume, VM, Preboot, Update,
  xarts, iSCPreboot and Hardware, two CoreSimulator images, and the two `smbfs` HomeLab shares (an unreachable share would stall the scrape).
  The rule is a mount-point include (`^/System/Volumes/Data$`, `^/Volumes/[^/]+$`) plus `apfs` and `hfs`.
- **Not scraped on purpose.** `system.network.connections` (one `lsof` run per scrape), the per-process scraper (one series per process),
  `icmp_check` (linewatch probes the line and exports through this agent), Docker (the mini's services are launchd-native), temperature
  (Linux only).
- **OTLP in.** An app sends traces, metrics and logs to `127.0.0.1:4417` with no key. The agent adds `host.name`, adds
  `deployment.environment.name` when the app set none, and leaves the app's own `service.name` alone. Only the agent holds the key. Each app
  moves to it in its own later change.
- **Secrets.** The wrapper reads the endpoint and key through `secrets-run` at start: nothing on disk, nothing in the plist. The MacBook's
  backend is `op`, which a LaunchAgent cannot answer, so `make agent-setup` there reads the two refs once into
  `~/.config/host-agent/agent.env` (mode 600, refused otherwise, rewritten on every run so a rotated key is picked up); the wrapper reads it as `KEY=value`
  data, never sources it, so a value is written bare, without quotes.
- **Run from the main checkout.** The plist points at `agent/` in the checkout that ran `make agent-setup`; the doctor fails a program inside
  `/.claude/worktrees/`.

## Retry patch

The stock `otlphttp` exporter retries only 429, 502, 503 and 504; every other status is a permanent error that drops the batch, and no config
option changes that. A Cloudflare 530 from the tunnel (2026-11-18 04:00Z, 91 and 32 items) was dropped that way and left a gap in ClickStack.
`scripts/host-agent-install.sh` therefore builds with a copy of the pinned exporter module in which `isRetryableStatusCode` also accepts 500 to
599 except 501 (a `replaces` entry appended to the manifest at build time; the tracked manifest is unchanged). The build fails loudly if the
function changed upstream. The `retry-5xx` marker is part of the build stamp. Verified 2026-11-18 against a local server answering 530 twice, then
200: three requests, no drop. `vps/agent` builds the same exporter and carries the same gap (signal filed).

## Update

Change the version in `agent/manifest.yaml` (every module) **and** `vps/agent/manifest.yaml` (this one is a copy), then `HOST_AGENT_VERSION` and
`OCB_VERSION` in the Makefile, then `make agent-setup` on each machine: the stamp (version, ocb release, manifest sha) differs, so it builds, installs
atomically and restarts the loaded agent. A build needs Go (`brew install go`) and the network.

## Verified 2026-11-17

| Check | Result |
|-|-|
| `system.cpu.utilization`, `system.memory.utilization`, `system.filesystem.utilization`, `system.network.io` with `host.name=mini` on prod ClickStack | present |
| Egress blocked 10 min (21:39:04 to 21:49:39 UTC, `HTTPS_PROXY` pointed at a closed port for the agent), then restored | every 30 s sample of the window arrived with its original timestamp |
| A span POSTed to `127.0.0.1:4417` with no key | in ClickStack with `host.name=mini`, `deployment.environment.name=prod` |
| `make agent-status` / `make doctor` | host-agent section green; during the blackout the export check warned |

## Footprint

Measured on the mini, 2026-11-17, agent 0.165.0, after one hour of continuous running (21:49:39 to 22:49:39 UTC; sampled every 2 min):

| | |
|-|-|
| Binary | 45 MB (`~/.local/bin/host-agent`) |
| Physical footprint (`top` mem, what `make mini-ps` budgets) | 28 to 30 MiB, flat over the hour |
| RSS (`ps`) | 59 MiB after the start (queue replay and first batches), settling to 44 to 46 MiB |
| CPU | 87.9 s of CPU time in 3600 s: 2.4 % of one core on average, constant (not just at start) |
| Rows to ClickStack | about 350,000 a day: roughly 91 series every 30 s and 61 every 60 s, derived from the series counts ClickStack reports per metric (it has no row-count query for metrics), network being 60 of the 91 |
| Queue on disk | 1.6 MiB after the 10-minute blackout |

The registry budget is 45 MiB (1.5 times the footprint, `rules/run-on-mini.md`); `memory_limiter` caps the process at 96 MiB. The 2.4 %
CPU is not split by component; the network scraper runs `netstat` on every tick, which is the first suspect. If the mini's CPU matters, the
first lever is the fast interval (30 s to 60 s should about halve it, unmeasured).

## Parity with Beszel and the heartbeat

The vps alert design maps Beszel's rules to ClickStack (`vps/docs/observability.md` §Against Beszel). Beszel on the mini alerts on: status
(connection down), memory, disk above 90 %, CPU 80 % for 10 min and load average 10 for 10 min (the last two to the `watchdog` topic, as a
digest). Nothing is alerted from ClickStack for the mini yet: the dashboards and alerts are the vps repo's (filed as a signal).

| Beszel alert / heartbeat check | ClickStack metric that now carries it | Not covered |
|-|-|-|
| Beszel status (agent connection down) | `system.cpu.utilization` etc. stop arriving: the per-host "host silent" alert (vps) | the alert for `host.name=mini` does not exist until vps adds it |
| Beszel memory | `system.memory.utilization` (`state` attribute) | Beszel's number counts cache differently from the OS-level state split; compare before moving the threshold |
| Beszel disk above 90 % | `system.filesystem.utilization` for `/System/Volumes/Data` | none |
| Beszel CPU 80 % for 10 min | `system.cpu.utilization` | none |
| Beszel load average 10 | `system.cpu.load_average.{1m,5m,15m}` | the VPS threshold is per core; the mini's is not |
| `check_disk` (93 % used, 20 GiB free) | `system.filesystem.utilization` and `system.filesystem.usage` | `check_disk` reads `df` of `$HOME`, same volume; the free-GiB floor is `usage` with `state=free`, a threshold to write in vps |
| `check_memory`: kernel memory pressure level (normal, warn, critical) | **not carried** | `host_metrics` has no macOS pressure level; it stays in the heartbeat |
| `check_memory`: swap in use as a share of RAM | `system.paging.usage` (`state=used`) divided by the RAM total (`system.memory.usage`, all states summed) | `system.paging.utilization` is the share of the swap file's *current* size, which macOS grows and shrinks: the heartbeat deliberately judges against RAM, so a ClickStack alert must too |
| `check_swapouts`: swapout rate per 300 s | **not carried**: `system.paging.operations` (`direction=page_out`) counts every page-out, file-backed ones included, not the swapfile swapouts the heartbeat reads from `sysctl vm.swapusage`/`vm_stat` | the rate that paged on 2026-09-27 stays in the heartbeat |
| `check_external_volume`, `check_ext_mirror` | `system.filesystem.*` for the `/Volumes/<name>` mount (present only while mounted) | the lock, mirror freshness and the 36 h rule stay in the heartbeat |
| Beszel network | `system.network.io`, `.errors`, `.dropped` (`en*`) | tunnel interfaces (Tailscale, VPN) are not scraped |
| Beszel temperature | **not carried** | not a Beszel alert either (`watchdog` thermal, homelab); `hardware` is Linux only |

The heartbeat is not replaced: it grades services, accounts, jobs and the registry, which no host metric carries, and it is the dead-man
signal when the network is gone (the agent only reports over the network).
