---
name: router
description: Read the home TP-Link VX800v router — Wi-Fi bands (SSID, channel, width, band steering), connected Wi-Fi/wired clients, the G.fast line (sync rates, noise margin, attenuation), firmware, CPU/memory — via the `routerctl` CLI. Use when the user asks about home Wi-Fi, the router, which devices are connected, signal or channel problems, slow LAN/Wi-Fi, or the internet line's physical state. For outage/speed history use linewatch instead.
---

# Router — TP-Link VX800v

`routerctl` is a **read-only** CLI over the router's GDPR web API
(`tplinkrouterc6u`'s `TPLinkEXClientGCM`, uv inline deps — no install).

```bash
R=~/.claude/skills/router/scripts/routerctl
$R status            # firmware, band steering, both bands, line, CPU/mem
$R wifi              # per band: SSID, channel, auto?, width (configured + current), security
$R clients           # Wi-Fi clients (band, signal, rates) + wired clients (link speed)
$R line              # DEV2_FAST_LINE (the real carrier) + DEV2_DSL_LINE
$R oids 'WIFI|STEER' # list data-model objects (585 DEV2_* exist)
$R raw DEV2_WIFI_BANDSTEERING --op go   # any object, secrets redacted
$R --json status     # every command takes --json
```

Each call logs in, reads, logs out (~5–10 s). **The router allows one admin
session**: a call logs the web UI out, and an open web UI session can make a
call fail — retry once, then ask whether the UI is open.

## Credentials (resolved in this order)

1. `ROUTER_PASSWORD` env.
2. `~/.config/linewatch/router-password` — present on the mini (linewatch's poller).
3. `secrets-run read op://Private/WLAN Router TP-Link/password` — the MacBook
   (biometric). The mini's cache refuses `Private` refs, so (2) is its path.

Host: `ROUTER_HOST`, default `https://192.168.1.1`. Both machines are on the
router's LAN at home; neither reaches it when away.

## Traps on this firmware (800.0.20) — all measured

- **Username is `user`, not `admin`**, and only the **HTTPS** UI works (plain
  HTTP serves a "welcome" interstitial on every path). Self-signed cert.
- **`Connection: close` is required** — a reused keep-alive socket returns
  `BadStatusLine('c\r\n')` (the open upstream bug other VX800v users hit).
- **`TplinkRouterProvider.get_client()` fails** (no client's `supports()`
  matches) and `get_status()` crashes on `DEV2_ADT_LAN` returning nothing.
  `routerctl` reads objects directly instead.
- **`gl` for list objects.** `go` on a list silently returns only the first
  instance.
- **`getGDPRParm` sometimes answers without RSA params** — login retries 4× with backoff.
- **Status fields lie:** `DEV2_DSL_LINE` says `Down` while the line is up —
  the carrier is **G.fast** (`DEV2_FAST_LINE`). IPv4 runs over **DS-Lite**, so
  every IPv4 WAN entry in `DEV2_ADT_WAN` reads not-connected on a working line.
- **Client table:** `DEV2_WIFI_APDEV_ASSOCDEV` keeps departed clients and its
  `active` flag is wrong (a connected MacBook reads 0). `signal` is not dBm —
  treat it as a relative number, higher is better. For "is X online", ping it.
- Failed logins count toward a lockout — don't loop on a wrong password.

## Writes — none here, deliberately

Config changes (band steering, channels, width, SSIDs) go through the web UI:
**Erweitert → WLAN → WLAN-Einstellungen** (per-band tabs; Band Steering is a
separate switch at the bottom of the same page). Writes are `so` ACTs on
`DEV2_ADT_WIFI_COMMON` / `DEV2_WIFI_BANDSTEERING`, untested — a wrong one drops
every Wi-Fi client, including the session issuing it. Add one only with the
owner present and a verified read-back.

WAN reconnect and router reboot exist, guarded, in linewatch:
`make router-reconnect` / `make router-reboot` on the mini (need
`LINEWATCH_ROUTER_WRITE=1`).

## History lives in linewatch (mini)

linewatch (`~/SourceRoot/linewatch`, mini only) records uptime (native ICMP),
hourly Ookla speed tests, and a 10-minute router poll (line samples, interfaces,
hosts). Its API on `:7731` (`/api/status`, `/api/verdicts`, `/api/outages`,
`/api/throughput`, `/api/router`, `/api/router/line`, `/api/wifi`) answers "was the line bad last
week" — `routerctl` answers "what is the router doing right now". linewatch is a
public repo: personal tooling belongs here, not there. Its `docs/router-spike.md`
is the protocol reference for this unit.

## Diagnosing slow Wi-Fi

1. `system_profiler SPAirPortDataType` on the client — band, channel, width,
   signal/noise, and the neighbours' channels.
2. `routerctl wifi` — what the router broadcasts, and whether band steering is on.
3. 2.4 GHz: pick a non-overlapping channel (1, 6, 11, 13 in DE) free of the
   neighbours. 5 GHz: 80 MHz on 36–48 avoids the DFS radar wait that 160 MHz
   (36–64) triggers after every change, and reaches further.
4. Distance beats settings: at ~20 m through walls, 5 GHz may not reach at all —
   the fix is a cable or an EasyMesh access point (the VX800v is an EasyMesh
   controller), not a router setting.
