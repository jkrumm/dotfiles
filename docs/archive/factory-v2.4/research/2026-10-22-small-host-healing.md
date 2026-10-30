# Research: 2026-10-22-small-host-healing

Job `382ddeb9-4616-4ed8-9672-fd35f5694397` · depth standard · status partial

**Query:** Self-healing, anomaly and attack detection for a solo operator's small Docker hosts (two Linux Docker hosts plus a macOS host), verified October 2026: docker-autoheal and alternatives (Docker restart policies with healthchecks, Watchtower successors), Robusta outside Kubernetes, Falco on plain Docker, Wazuh footprint, Netdata ML anomaly detection (how it works, false-positive behaviour, licence of agent vs cloud), CrowdSec with Caddy/Traefik bouncers and its blocklist, Beszel alerts, Uptime Kuma 2.x API/webhooks for recovery events. For each: licence, latest version and date, maintenance status, resource footprint, what it detects or heals, how it exposes events (webhook/API) for an external correlation loop, and known failure modes.

> **Partial result — evidence was lost during this run.** 1 claim(s) were dropped because the pages backing them could not be retrieved; 1 source(s) named in the report body could not be verified and are flagged inline below. Anything below that is not backed by an entry in `citations` is unconfirmed; see `unverified` for what could not be checked.

> **Unverified in prose:** this report references <https://github.com/henrygd/beszel/security/advisories/GHSA-759g-ch5m-2gch>, which this run could NOT verify (Seen only as a truncated search-result snippet; the advisory page itself was never fetched, so scope and fixed version are unconfirmed.). Treat that reference as unconfirmed — see `unverified`.

## Bottom line

- **Healing:** Docker's `--restart` policy fires only on container *exit* or daemon restart — an `unhealthy` container whose process still runs is never restarted by it, so `willfarrell/autoheal` (MIT) is still the practical self-healer, on a daily-rebuilt image but a low-velocity repo.
- **Updates:** `containrrr/watchtower` is **archived and unmaintained** (last release v1.7.1, 2023-11-11); **Diun 4.33.0** (2026-05-30) and **WUD 9.5.0** (2026-10-18) are the actively released MIT checkers.
- **Runtime detection:** **Falco** is the only one of the three host-threat tools that genuinely runs Docker-only — 0.45.1 (2026-10-19), Apache-2.0, eBPF, ~47 MB, **no built-in healing**. **Wazuh** works agent-only (agent "35 MB of RAM on average", 4.14.9) but its real cost lands on a manager (min 2 GB/2 cores) and a 5.0-rc soak showed managers discarding ~36 M events. **Robusta has no non-Kubernetes mode at all.**
- **Metrics anomaly:** Netdata ML is per-dimension k-means (k=2) whose anomaly bit is set only when **all** models agree; 2.12.1 is still current (2026-10-08); Agent GPL-3.0, Cloud closed-source. Its only shipped ML alert is `to: silent`, so nothing notifies until you write the rule.
- **Alerts:** Beszel (MIT, v0.21.0, 2026-10-02) and Uptime Kuma (MIT, 2.5.6, 2026-10-09) both expose transitions, but **neither emits a typed `recovered` event** — Beszel re-sends the same alert with English "below threshold" text; Kuma's webhook carries `heartbeat.status === 1`.
- **CrowdSec:** both bouncers are third-party Apache-2.0. The Traefik plugin **fails closed by default** (`updateMaxFailure: 0` ⇒ 403s when LAPI is unreachable, which Uptime Kuma will read as a service outage); the Caddy bouncer's `enable_hard_fails` defaults **false**.

*Verification date: 2026-10 (registry/release timestamps observed through 2026-10-22).*

---

## 1. Native restart policies vs autoheal

Docker's restart-policy page enumerates the triggers as `no`, `on-failure[:max-retries]`, `always`, `unless-stopped` — **all keyed to the container exiting or the daemon restarting**. Two caveats matter for a solo operator: a policy "only takes effect after a container starts successfully… up for at least 10 seconds", and "If you manually stop a container, the restart policy is ignored until the Docker daemon restarts or the container is manually restarted." `on-failure` additionally "doesn't restart the container if the daemon restarts." ([docs.docker.com](https://docs.docker.com/engine/containers/start-containers-automatically/), high)

HEALTHCHECK gives a container "a health status **in addition to** its normal status" (`starting`→`healthy`/`unhealthy`; `--interval` 30s, `--timeout` 30s, `--start-period` 0s, `--start-interval` 5s on Engine 25.0+, `--retries` 3), and "when the health status of a container changes, a `health_status` event is generated". No restart-on-unhealthy behaviour is documented ([docs.docker.com](https://docs.docker.com/reference/dockerfile/), high). Autoheal's README confirms this is by design — `--exit-on-unhealthy` "didn't make the cut" ([README](https://github.com/willfarrell/docker-autoheal/blob/HEAD/README.md), high).

**Useful for the loop:** because the daemon emits `health_status`, `die` and `start` on its events stream, `GET /events` on the socket is already a free, structured heal/health feed — no extra component needed for the "container went unhealthy then restarted" story.

**willfarrell/autoheal:** MIT, 2,015 stars, 61 open issues, last push 2025-09-09, **no GitHub releases** (image tags only) ([repo](https://github.com/willfarrell/docker-autoheal), high). Docker Hub `latest` rebuilt **2026-10-22** (README: "Built daily"), newest numbered tag 1.2.0 (2021-07-08), `latest` 5,798,134 bytes ([Hub](https://hub.docker.com/r/willfarrell/autoheal), high). It heals *only* unhealthy containers (needs a HEALTHCHECK; label `autoheal=true`, `AUTOHEAL_CONTAINER_LABEL=all`, or custom). Defaults: `AUTOHEAL_INTERVAL=5`, `AUTOHEAL_START_PERIOD=0`, `AUTOHEAL_DEFAULT_STOP_TIMEOUT=10`, `CURL_TIMEOUT=30`, `AUTOHEAL_ONLY_MONITOR_RUNNING=false`, per-container `autoheal.stop.timeout`. Event exposure is a single `WEBHOOK_URL` POST "if a container was restarted (or restart failed)". Failure modes: 5-second polling granularity, no rate-limiting on restart loops (a flapping container is restarted every interval), and it needs the raw docker socket — root-equivalent.

## 2. Watchtower and its successors

`containrrr/watchtower` is **archived: true**, Apache-2.0, 24,612 stars, 219 open issues, last push 2025-12-17; latest release **v1.7.1 (2023-11-11)**; README opens "⚠️ This project is no longer maintained" ([repo](https://github.com/containrrr/watchtower), [README](https://github.com/containrrr/watchtower/blob/HEAD/README.md), high). Docker Hub corroborates: 160 tags, newest release tag `1.7.1` pushed 2023-11-11, only `latest-dev` newer (2024-01-03) ([Hub](https://hub.docker.com/r/containrrr/watchtower), medium); third-party write-ups date the archive to 17 December 2025 ([bigiron.cc](https://www.bigiron.cc/guides/after-watchtower-a-container-update-routine-with-diun-and-pinned-tags), medium). **Any remaining Watchtower path is a frozen, root-equivalent image receiving no security patches.**

Maintained replacements (versions verified; behaviour not):

| Tool | Licence | Latest | Date | Repo activity |
|---|---|---|---|---|
| Diun | MIT | 4.33.0 | 2026-05-30 | last push 2026-10-16, 114 open issues ([repo](https://github.com/crazy-max/diun), high) |
| WUD (What's Up Docker) | MIT | 9.5.0 | 2026-10-18 | last push 2026-10-21, 63 open issues ([repo](https://github.com/getwud/wud), high) |

Third-party sources also name a maintained fork at `nicholas-fedor/watchtower` as a drop-in with identical configuration, plus Tugtainer, dockcheck and drydock ([watchtowerdocker.com](https://watchtowerdocker.com/), medium). **Note the distinction for your setup: Diun and WUD are update *notifiers/checkers* — they detect a new image tag. Only Watchtower-class tools (or the fork) actually recreate containers.** WUD's trigger/API surface and Diun's notification behaviour were not verified this run.

## 3. Falco — Docker-only runtime detection

Apache-2.0, **0.45.1 released 2026-10-19**, repo pushed 2026-10-20, CNCF-graduated, 42 open issues ([repo](https://github.com/falcosecurity/falco), high). Image `falcosecurity/falco:0.45.1` pushed 2026-10-19, amd64 **47,015,704 bytes** (debian variant 92,274,912); `latest` is a moving tag ([Hub](https://hub.docker.com/r/falcosecurity/falco), high).

Falco's docs document the non-orchestrated path explicitly: "orchestration systems like Kubernetes are out of scope for this section, it's up to the user to manage the container lifecycle" ([falco.org](https://falco.org/docs/setup/container/), high). **Modern eBPF is bundled in the binary** — no driver install, no kernel headers; needs ring-buffer + BTF (usually ≥5.8). Least privilege: `--cap-drop all --cap-add sys_admin --cap-add sys_resource --cap-add sys_ptrace` (minimal set is CAP_SYS_BPF/PERFMON/RESOURCE/PTRACE; `SYS_ADMIN` stands in because "Docker does not yet support CAP_BPF and CAP_PERFMON"). Mounts: `/proc:/host/proc:ro`, `/etc:/host/etc:ro`, `/var/run/docker.sock`, optional `/sys/kernel/tracing:ro`. The kmod driver instead "requires full privileges and cannot run with Linux capabilities", needs `/dev/falcoX` per CPU and `apparmor:unconfined` on AppArmor hosts ([falco.org](https://falco.org/docs/concepts/event-sources/kernel/), high).

Host PID namespace is **strongly recommended, not mandatory**: `falco.yaml` says BPF iterators auto-disable "whenever Falco is not running in the host (root) PID namespace… since in that case they would not have full visibility into host processes" ([falco.yaml](https://github.com/falcosecurity/falco/blob/HEAD/falco.yaml), high).

**Egress for your loop:** `stdout_output`, `syslog_output`, `file_output`, `http_output` (webhook, requires `json_output`), `program_output` (arbitrary command), plus an embedded webserver on :8765 (`/healthz`, `/versions`, `/reload`, optional Prometheus). **No built-in remediation** — response is external.

**Known failure modes:** kernel BTF/ringbuf gaps; 0.45 BPF atomics need Linux 5.12 else it logs "no BPF atomics on this kernel"; `syscall_event_drops` threshold 0.1 (log+alert, 1 msg/30 s); `outputs_queue.capacity: 0` is an **unbounded queue → OOM kill** risk; `buf_size_preset: 4` = 8 MB/CPU with 5 (16 MB) recommended for heavy hosts; defaults are noisy (`priority: debug`, `rule_matching: first` shadowing later rules); and the privileged-plus-docker.sock combination is host-root-equivalent, so the sensor itself is a large blast radius.

## 4. Wazuh — agent-only works, but the bill is on the manager

**4.14.9 stable (2026-10-15)** plus a **5.0.0-rc1** container (2026-10-05) — two live lines ([Hub](https://hub.docker.com/r/wazuh/wazuh-agent), high). Licence splits: mostly GPLv2, **`src/engine/` is AGPLv3**, shared libs dual `GPL-2.0-only OR AGPL-3.0-or-later` ([LICENSE](https://github.com/wazuh/wazuh/blob/HEAD/LICENSE), high).

Agent: docs claim it "requires 35 MB of RAM on average"; image ~75.8 MB amd64; capabilities are log collection, command execution, FIM, SCA, inventory, malware detection, Active Response, container security ([docs](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html), high). Server: **min 2 GB/2 cores, rec 4 GB/8 cores**, vulnerability-detection DB ~11 GB, **≥20 GB free on `/var/ossec`** before first start, 0.1 GB/agent/90 days alert storage for servers ([docs](https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html), high).

Wazuh **can heal** (Active Response / command execution — the only one of the three that can), but egress is agent→manager over an encrypted channel, so your correlation loop must consume the **manager**, not the agent.

**Documented overload signals:** `/var/ossec/var/run/wazuh-analysisd.state` (`events_dropped`) and `wazuh-remoted.state` (`discarded_count`), both "should be zero". A 36-hour soak of 5.0.0-rc1 with 40 containerized agents on 2 Docker hosts: agents never OOM'd (restart_count 0), but **managers discarded 36.2 M / 37.0 M events against a limit of 0**, indexers sustained 389.5%/391.8% CPU p95 against a 200% limit, **27,743,976 / 27,902,920 documents were not indexed**, IT-Hygiene drifted 24.68% (limit 5%), and the daily tasks.db VACUUM spikes modulesd by +460 MB in 5 seconds ([issue #40062](https://github.com/wazuh/wazuh/issues/40062), high). On a two-host fleet this is the concrete reason to keep Wazuh out of the critical path.

## 5. Robusta — no non-Kubernetes mode

MIT, **0.53.0 (2026-10-15)** ([repo](https://github.com/robusta-dev/robusta), high). "Standalone" means *Kubernetes without Prometheus*: prerequisites are "A supported Kubernetes cluster" and Helm ([docs](https://docs.robusta.dev/reports-docs/setup-robusta/installation/standalone-installation.html), high). Architecture is two K8s deployments (`robusta-forwarder` watching the APIServer, `robusta-runner` executing playbooks) plus an "agentless mode" that still "can monitor a cluster from the outside" ([docs](https://docs.robusta.dev/master/user-guide/architecture.html), high). Open-core: the free UI account gates timeline and AI RCA. **It cannot monitor a plain Docker host — rule it out.**

## 6. Netdata ML anomaly detection

**2.12.1 is still current**: GitHub `latestRelease` v2.12.1 published 2026-10-08T16:52:35Z; Docker Hub `stable`/`v2.12.1` pushed 2026-10-08, only `edge`/nightly rolling tags newer (2026-10-22) ([repo](https://github.com/netdata/netdata), [Hub](https://hub.docker.com/r/netdata/netdata), high). Nothing newer has shipped.

**How it works:** unsupervised k-means, **k=2 per dimension**, on preprocessed vectors (lag=5, smooth=3, diff=1, 20% random sampling) using dlib — no deep learning. Defaults: max 21,600 / min 900 training samples, retrain every 3 h, **18 models per dimension** (~54 h of staggered coverage). New points are scored by Euclidean distance from cluster centres; a model flags the point when distance exceeds the **99th percentile** of training data ([src/ml/README.md](https://github.com/netdata/netdata/blob/HEAD/src/ml/README.md), high).

**False-positive behaviour:** the anomaly bit is set to 100 only if **ALL** models agree — docs state this "reduces false positives by approximately 99%" (vendor claim, not an independent benchmark) ([ml-configuration.md](https://github.com/netdata/netdata/blob/HEAD/src/ml/ml-configuration.md), high). Rates: **DAR** = per-dimension average over time, **NAR** = average across the node at a time point. Node events fire when NAR exceeds `host anomaly rate threshold` (default **1.0%**) for `anomaly detection grouping duration` (default 5 m).

**Surfacing:** (i) the bit is embedded in the stored number, queryable with `options=anomaly-bit` on `/api/v1/data` returning 0 or 100; (ii) charts `anomaly_detection.dimensions` / `anomaly_detection.anomaly_rate`; (iii) node events as the `new_anomaly_event` dimension. **Trap for your loop:** the only shipped template, `ml_1min_node_ar`, watches `average -1m of anomaly_rate` with `warn: $this > 1`, `every: 30s`, and is routed **`to: silent`** — no notification leaves the box unless you write your own `warn/crit` with hysteresis ([health.d/ml.conf](https://github.com/netdata/netdata/blob/HEAD/src/health/health.d/ml.conf), high). Node-level anomaly events are also **lagging**: the Anomaly Advisor notes events appear slightly after rates rise because a large share of metrics must be anomalous ([learn.netdata.cloud](https://learn.netdata.cloud/docs/dashboards-and-charts/anomaly-advisor-tab), high). ML costs ~1–2% of one core at defaults.

**Licence split:** **Agent = GPLv3+** (collection, storage, ML, alerting, APIs); **Cloud = closed-source, free and paid tiers** (remote access, SSO, centralized alerts, RBAC); **UI = NCUL1**, closed but free ([README](https://github.com/netdata/netdata/blob/HEAD/README.md), high). Cloud is optional; everything above runs agent-side.

## 7. Beszel

**MIT, v0.21.0 (2026-10-02)**, last push 2026-10-21, 26.4k stars, 204 contributors — actively maintained ([repo](https://github.com/henrygd/beszel), high). Hub is a PocketBase web app, agent per host. **Footprint figures were not obtainable** (see unverified).

Alert rules in v0.21.0: `CPU`, `Memory`, `Bandwidth`, `Disk`, `Temperature`, `LoadAvg1/5/15`, `GPU`, `Battery`, `CPUIOWait`, `CPUSteal`; `Status`, systemd-failed, container and network-monitor-loss are on separate binary-state paths. Thresholds carry a duration `min`: values are averaged over 1-minute `system_stats` rows and only evaluated when sample count ≥ min/1.2; Disk takes the max across partitions/ZFS pools ([alerts_system.go](https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts_system.go), high).

**Delivery and the recovery problem:** notifications go through Shoutrrr URLs; with `generic://…?template=json` the POST body is `{"title":"…","message":"…"}` ([generic docs](https://beszel.dev/guide/notifications/generic), high). Title on trigger is `"<system> <metric> above threshold"`; **recovery is the same alert re-sent as `"<system> <metric> below threshold"`** — no event type, no ID ([alerts_system.go](https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts_system.go), high). The machine-readable option is the **heartbeat**: `HEARTBEAT_URL`, 60 s default, POST JSON `{status, timestamp, msg, systems{total,up,down,paused,pending}, down_systems[], triggered_alerts[{system_id,system_name,alert_name,threshold}], beszel_version}` — a polled snapshot, so **diff `down_systems` between beats** ([heartbeat docs](https://www.beszel.dev/guide/heartbeat), high).

**Failure modes:** alert evaluation lives in the hub (hub down ⇒ no alerts); delivery is gated at send time — `SendAlert` returns silently if the alerting user no longer has system access, quiet-hours windows drop notifications, and webhooks only leave via `shoutrrr.Send` when the owner is admin ([alerts.go](https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts.go), high). An advisory **GHSA-759g-ch5m-2gch** (Sept 2026) describes an authenticated IDOR in `/api/beszel/user-alerts` allowing alert subscription on systems you do not own ([advisory](https://github.com/henrygd/beszel/security/advisories/GHSA-759g-ch5m-2gch), medium — seen only as a search snippet).

## 8. Uptime Kuma 2.x

**2.5.6, released 2026-10-09** (GH release 2026-10-09T15:46:26Z; Hub tags `2.5.6`/`2`/`2-slim`/`2-rootless` pushed same day), MIT, not archived, last push 2026-10-22 ([repo](https://github.com/louislam/uptime-kuma), [Hub](https://hub.docker.com/r/louislam/uptime-kuma), high).

**There is no documented REST API for monitors or events.** The official wiki: the project "primarily uses Socket.io for real-time communication after authentication", with REST only for push monitors (`/api/push/:pushToken`), `/metrics`, SVG badges and public status-page JSON — and warns it is "not officially supported for third-party integrations. Breaking changes may occur between versions without prior notice." ([wiki](https://github.com/louislam/uptime-kuma/wiki/Internal-API), high). A 2026-09-05 third-party audit of 2.5.3 agrees ("no REST API for managing monitors") and adds that the API key authenticates **only** `/metrics`, 60 req/min ([uptimepage.dev](https://uptimepage.dev/blog/uptime-kuma-rest-api), medium).

Read state without Socket.IO via `monitor_status` 0–3 on `/metrics`, or a *public* status page. **The webhook is the transition channel:** 2.5.6 POSTs `{ heartbeat, monitor, msg }` (supports form-data and a LiquidJS `custom` body); `monitor` carries id/name, and `heartbeat` carries `status: 0=DOWN, 1=UP, 2=PENDING, 3=MAINTENANCE` plus `monitorID, time, msg, ping, important, duration, retries, response` ([webhook.js](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/notification-providers/webhook.js), [heartbeat.js](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/model/heartbeat.js), high). **Recovery = `heartbeat.status === 1` following a `0`, keyed by `monitorID`.**

**v1→v2:** the migration guide lists no REST-route or webhook-payload breaking change (only badge formats, browser support, backup/restore, DNS cache, default retries, and Email templating moving to LiquidJS). A 1.x webhook receiver keeps working; the risk is the wiki's "may break without notice" caveat ([migration guide](https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2), high).

## 9. CrowdSec bouncers and decisions

Core established: CrowdSec 1.8.1, MIT.

- **Caddy** (`hslatman/caddy-crowdsec-bouncer`, third-party): **Apache-2.0, v0.14.1 (2026-08-03)**, last push 2026-09-10, 433 stars ([repo](https://github.com/hslatman/caddy-crowdsec-bouncer), high). Keeps decisions locally, polling LAPI every 60 s (`ticker_interval`) via StreamBouncer, or per-request via LiveBouncer. Blocks by default; captcha and custom actions remain roadmap items. **Failure mode: `enable_hard_fails` defaults `false`** — Caddy still starts if the LAPI is unreachable and keeps enforcing decisions it already holds ([README](https://github.com/hslatman/caddy-crowdsec-bouncer/blob/HEAD/README.md), high).
- **Traefik** (`maxlerebourg/crowdsec-bouncer-traefik-plugin`, third-party): **Apache-2.0, v1.8.1 (2026-10-18)**, last push 2026-10-21, 934 stars ([repo](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin), high). Modes `none/live/stream/alone/appsec`; enforces 403 (`remediationStatusCode`) or captcha/WAF. **Fails closed by default:** `updateMaxFailure: 0` = "maximum number of time we can not reach Crowdsec before blocking traffic (set -1 to never block)", `streamStartupBlock: true` waits for first sync, `crowdsecAppsecFailureBlock`/`crowdsecAppsecUnreachableBlock`/`redisCacheUnreachableBlock` all default `true` ([README](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/blob/HEAD/README.md), high). **Operational consequence for you: a LAPI outage on the Traefik path produces 403s that Uptime Kuma will report as an outage — a false "recovery needed" signal in the loop.**
- **Blocklist:** the Traefik plugin's `alone` mode consumes the CAPI community blocklist ("highly reported and validated IPs banned from the Crowdsec network") directly, refreshed every 2 h using `crowdsecCapiMachineId`/`crowdsecCapiPassword`, without a local engine (medium — third-party README description only). Blocklist contents, licence/terms and whether a paid Console tier is required **could not be verified**.
- **Export for your loop:** only CLI forms are verified — `cscli decisions add --ip 10.0.0.10 -d 10m [-t captcha]`, `cscli decisions remove`, `cscli bouncers add`. LAPI HTTP endpoints and notification/webhook plugins were not verified this run, and footprint figures were not obtained.

## 10. Wiring the correlation loop

No tool in this set emits a stable, typed `recovered` event. The most reliable machine hooks, in order: (1) **Docker `/events`** for `health_status`/`die`/`start` — the only true transition feed; (2) **Uptime Kuma webhook** with `heartbeat.status` 0/1 keyed by `monitorID`; (3) **Falco `http_output`** (JSON, webhook) for threat alerts; (4) **Beszel heartbeat diff** on `down_systems[]`; (5) **Netdata** — needs a self-authored health rule since the shipped ML alert is silent, then webhook from health notifications; (6) **Wazuh manager** (not the agent) if deployed; (7) **`cscli decisions list`** for CrowdSec state. Autoheal's single `WEBHOOK_URL` POST is a bonus confirmation of an actual restart, with payload shape unverified.

## Unverified

- `nicholas-fedor/watchtower` fork version/licence/activity — only GitHub navigation chrome was retrieved.
- Autoheal `WEBHOOK_URL` payload shape and log format (entrypoint script not read).
- WUD 9.5.0 trigger/API/metrics docs and Diun notification behaviour — no behaviour verified beyond version/licence/open-issue metadata.
- Watchtower's own archive discussion thread — not read.
- HolmesGPT Docker toolset as a non-Kubernetes monitoring path — page not read.
- Falco hardened-image guide — covered instead by falco.org docs and `falco.yaml`.
- Wazuh container-security use case for Docker hosts (log paths / docker.sock requirements) — page not read.
- Netdata Cloud pricing page (free-tier node limit and per-feature gating).
- Beszel agent/hub resource footprint — no figures obtained from any doc.
- Netdata v2.12.0/v2.12.1 release notes (what shipped since 2.11.x).
- Beszel advisory GHSA-759g-ch5m-2gch full scope and fixed version.
- CrowdSec Caddy remediation docs page (404 at that path; correct path not located), LAPI bouncer endpoint reference, remediation-components overview, and Hub listing cross-check.
- CrowdSec CAPI blocklist contents, licence/terms and Console paid-tier requirements, plus CrowdSec LAPI endpoints, notification plugins and typical CPU/RAM footprint.

## Citations

- [https://docs.docker.com/engine/containers/start-containers-automatically/](https://docs.docker.com/engine/containers/start-containers-automatically/) — confidence high
- [https://docs.docker.com/reference/dockerfile/](https://docs.docker.com/reference/dockerfile/) — confidence high
- [https://github.com/willfarrell/docker-autoheal/blob/HEAD/README.md](https://github.com/willfarrell/docker-autoheal/blob/HEAD/README.md) — confidence high
- [https://github.com/willfarrell/docker-autoheal](https://github.com/willfarrell/docker-autoheal) — confidence high
- [https://hub.docker.com/r/willfarrell/autoheal](https://hub.docker.com/r/willfarrell/autoheal) — confidence high
- [https://github.com/containrrr/watchtower](https://github.com/containrrr/watchtower) — confidence high
- [https://github.com/containrrr/watchtower/blob/HEAD/README.md](https://github.com/containrrr/watchtower/blob/HEAD/README.md) — confidence high
- [https://hub.docker.com/r/containrrr/watchtower](https://hub.docker.com/r/containrrr/watchtower) — confidence medium
- [https://www.bigiron.cc/guides/after-watchtower-a-container-update-routine-with-diun-and-pinned-tags](https://www.bigiron.cc/guides/after-watchtower-a-container-update-routine-with-diun-and-pinned-tags) — confidence medium
- [https://github.com/crazy-max/diun](https://github.com/crazy-max/diun) — confidence high
- [https://github.com/getwud/wud](https://github.com/getwud/wud) — confidence high
- [https://watchtowerdocker.com/](https://watchtowerdocker.com/) — confidence medium
- [https://github.com/falcosecurity/falco](https://github.com/falcosecurity/falco) — confidence high
- [https://hub.docker.com/r/falcosecurity/falco](https://hub.docker.com/r/falcosecurity/falco) — confidence high
- [https://falco.org/docs/setup/container/](https://falco.org/docs/setup/container/) — confidence high
- [https://falco.org/docs/concepts/event-sources/kernel/](https://falco.org/docs/concepts/event-sources/kernel/) — confidence high
- [https://github.com/falcosecurity/falco/blob/HEAD/falco.yaml](https://github.com/falcosecurity/falco/blob/HEAD/falco.yaml) — confidence high
- [https://github.com/wazuh/wazuh](https://github.com/wazuh/wazuh) — confidence high
- [https://github.com/wazuh/wazuh/blob/HEAD/LICENSE](https://github.com/wazuh/wazuh/blob/HEAD/LICENSE) — confidence high
- [https://hub.docker.com/r/wazuh/wazuh-agent](https://hub.docker.com/r/wazuh/wazuh-agent) — confidence high
- [https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html) — confidence high
- [https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html](https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html) — confidence high
- [https://github.com/wazuh/wazuh/issues/40062](https://github.com/wazuh/wazuh/issues/40062) — confidence high
- [https://github.com/robusta-dev/robusta](https://github.com/robusta-dev/robusta) — confidence high
- [https://docs.robusta.dev/reports-docs/setup-robusta/installation/standalone-installation.html](https://docs.robusta.dev/reports-docs/setup-robusta/installation/standalone-installation.html) — confidence high
- [https://docs.robusta.dev/master/user-guide/architecture.html](https://docs.robusta.dev/master/user-guide/architecture.html) — confidence high
- [https://github.com/netdata/netdata](https://github.com/netdata/netdata) — confidence high
- [https://hub.docker.com/r/netdata/netdata](https://hub.docker.com/r/netdata/netdata) — confidence high
- [https://github.com/netdata/netdata/blob/HEAD/README.md](https://github.com/netdata/netdata/blob/HEAD/README.md) — confidence high
- [https://github.com/netdata/netdata/blob/HEAD/src/ml/README.md](https://github.com/netdata/netdata/blob/HEAD/src/ml/README.md) — confidence high
- [https://github.com/netdata/netdata/blob/HEAD/src/ml/ml-configuration.md](https://github.com/netdata/netdata/blob/HEAD/src/ml/ml-configuration.md) — confidence high
- [https://github.com/netdata/netdata/blob/HEAD/src/health/health.d/ml.conf](https://github.com/netdata/netdata/blob/HEAD/src/health/health.d/ml.conf) — confidence high
- [https://learn.netdata.cloud/docs/dashboards-and-charts/anomaly-advisor-tab](https://learn.netdata.cloud/docs/dashboards-and-charts/anomaly-advisor-tab) — confidence high
- [https://github.com/henrygd/beszel](https://github.com/henrygd/beszel) — confidence high
- [https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts_system.go](https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts_system.go) — confidence high
- [https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts.go](https://github.com/henrygd/beszel/blob/v0.21.0/internal/alerts/alerts.go) — confidence high
- [https://beszel.dev/guide/notifications/generic](https://beszel.dev/guide/notifications/generic) — confidence high
- [https://www.beszel.dev/guide/heartbeat](https://www.beszel.dev/guide/heartbeat) — confidence high
- [https://github.com/louislam/uptime-kuma](https://github.com/louislam/uptime-kuma) — confidence high
- [https://hub.docker.com/r/louislam/uptime-kuma](https://hub.docker.com/r/louislam/uptime-kuma) — confidence high
- [https://github.com/louislam/uptime-kuma/wiki/Internal-API](https://github.com/louislam/uptime-kuma/wiki/Internal-API) — confidence high
- [https://github.com/louislam/uptime-kuma/blob/2.5.6/server/notification-providers/webhook.js](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/notification-providers/webhook.js) — confidence high
- [https://github.com/louislam/uptime-kuma/blob/2.5.6/server/model/heartbeat.js](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/model/heartbeat.js) — confidence high
- [https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2](https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2) — confidence high
- [https://uptimepage.dev/blog/uptime-kuma-rest-api](https://uptimepage.dev/blog/uptime-kuma-rest-api) — confidence medium
- [https://github.com/hslatman/caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) — confidence high
- [https://github.com/hslatman/caddy-crowdsec-bouncer/blob/HEAD/README.md](https://github.com/hslatman/caddy-crowdsec-bouncer/blob/HEAD/README.md) — confidence high
- [https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin) — confidence high
- [https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/blob/HEAD/README.md](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/blob/HEAD/README.md) — confidence high

## Unverified (as reported by the job)

- {"topic": "nicholas-fedor/watchtower fork metadata (version, licence, activity)", "url": "https://github.com/nicholas-fedor/watchtower", "reason": "Only GitHub navigation chrome was retrieved before the README/metadata, so nothing about the fork could be verified."}
- {"topic": "autoheal webhook payload shape and entrypoint/log format", "url": "https://raw.githubusercontent.com/willfarrell/docker-autoheal/main/docker-entrypoint", "reason": "Entrypoint script could not be read, so the WEBHOOK_URL payload and log line format remain unverified; only the README description is verified."}
- {"topic": "WUD 9.5.0 API/trigger/metrics documentation and Diun notification behaviour", "url": null, "reason": "Only registry/GitHub metadata (version, date, licence, open issues) was verified for these tools; API and notification behaviour is unverified."}
- {"topic": "Watchtower archive discussion (containrrr/watchtower/discussions/2135)", "url": "https://github.com/containrrr/watchtower/discussions/2135", "reason": "Not fetched; the archived flag and README banner were verified directly, so the discussion thread's rationale remains unread."}
- {"topic": "HolmesGPT docker/core toolset as a non-Kubernetes Docker monitoring path in the Robusta ecosystem", "url": "https://docs.robusta.dev/improve_holmes_docs/configuration/holmesgpt/toolsets/docker.html", "reason": "Page not read; only a search-result snippet suggesting the integration is for HolmesGPT CLI, not cluster monitoring."}
- {"topic": "Falco hardened-image guide on modern eBPF privilege requirements", "url": "https://hub.docker.com/hardened-images/catalog/dhi/falco/guides", "reason": "Not fetched; the claim is covered instead by falco.org docs and the repo falco.yaml."}
- {"topic": "Wazuh container-security use case for Docker hosts (log paths and docker.sock requirements)", "url": "https://documentation.wazuh.com/5.0-rc/user-manual/capabilities/container-security/use-cases.html", "reason": "Not fetched, so the specific log paths and docker.sock requirements could not be verified from the page itself."}
- {"topic": "Netdata Cloud pricing page (free-tier node limit, per-feature gating)", "url": "https://www.netdata.cloud/pricing/", "reason": "Retrieved only as a search-result snippet; the node limit and feature split were not read on the page itself."}
- {"topic": "Beszel agent/hub resource footprint", "url": "https://www.beszel.dev/guide/what-is-beszel", "reason": "No footprint figures were obtained from any Beszel doc, so none are asserted."}
- {"topic": "Netdata v2.12.0 / v2.12.1 release notes (what shipped since 2.11.x)", "url": "https://github.com/netdata/netdata/releases", "reason": "Not fetched; only tag/publication dates were available, no changelog content could be read."}
- {"topic": "Beszel security advisory GHSA-759g-ch5m-2gch (IDOR in /api/beszel/user-alerts)", "url": "https://github.com/henrygd/beszel/security/advisories/GHSA-759g-ch5m-2gch", "reason": "Seen only as a truncated search-result snippet; the advisory page itself was never fetched, so scope and fixed version are unconfirmed."}
- {"topic": "CrowdSec LAPI endpoint reference for remediation components (/v1/decisions, /v1/alerts, streaming)", "url": "https://docs.crowdsec.net/docs/local_api/bouncers/", "reason": "Appears in search results but could not be fetched, so endpoint details are unverified."}
- {"topic": "CrowdSec Remediation Components overview (community vs first-party status, console/blocklist links)", "url": "https://docs.crowdsec.net/u/bouncers/intro/", "reason": "Appears in search results but could not be fetched."}
- {"topic": "CrowdSec Hub listing for caddy-crowdsec-bouncer (v0.14.1 cross-check)", "url": "https://app.crowdsec.net/hub/author/hslatman/remediation-components/caddy-crowdsec-bouncer", "reason": "Only seen as a search-result snippet; page never fetched, so the cross-check rests on the snippet alone."}
- {"topic": "CrowdSec CAPI blocklist / Console subscription terms and paid-tier requirements", "url": null, "reason": "No usable page retrieved; nothing about blocklist size, licence, terms or tier gating is asserted."}
- {"topic": "Advisory GHSA-759g-ch5m-2gch (Sept 2026) describes an authenticated IDOR in /api/beszel/user-alerts", "url": "https://github.com/henrygd/beszel/security/advisories/GHSA-759g-ch5m-2gch", "reason": "Citation dropped: this run reported the same URL as unverifiable, so it cannot support a claim."}
