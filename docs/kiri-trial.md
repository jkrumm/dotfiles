# kiri and Apple's container, a trial beside Colima

Plan row `kiri-trial`, Issue 1220, 2026-11-14. A trial only: nothing moved. Colima and the default docker context were
never touched: the only Colima commands were `ps` and one scratch `python:3.13-alpine` container with a bind of a scratch directory (step d, the bind-speed comparison). Colima was restarted by something else at about 20:56 local (`colima-start.sh`, not this trial); `docker --context colima ps` lists the same four containers (brain-web, dashboard-api, dashboard-ui, prometheus-vpn) before and after. The measurements are
repeatable: `make kiri-install kiri-up`, then `make kiri-trial STEP=a|b|c-…|d|e`, `make container-install
container-measure` (`kiri/`, raw logs in `~/.local/state/kiri-trial/`).

## Verdict

**Stay on Colima, at a fixed 2 GiB. Move nothing to kiri; Apple's container takes no always-on container.**

The owner's question after the plan changed (the VM is always on, so sleeping decides nothing): does the runtime give
memory back to macOS while containers keep running? **kiri does not.** After a container allocated and freed memory the
VM's footprint stayed where the peak left it, 2 minutes and 10 minutes later, at both ceilings (table (a)). The balloon
works inside the guest (the guest reported 3.9 of 4.0 GiB "used" with 160 MiB really in use: the pages sit in the
balloon) and the host does not reclaim them, which is what the earlier research run found. An always-on kiri VM
therefore costs the largest amount its containers ever touched, up to its ceiling, exactly as Colima's does (2062 MiB
now, at a 2 GiB ceiling, for about 1.05 GiB of containers). It starts lower and ratchets up; the 48-hour section below could not say how fast on
the real working set.

What kiri would add on top of that for this stack:

- **Fixed shares: the whole Mac.** The VM mounts the Mac's root filesystem read-write at `/mnt/mac`. `MAC_SHARES`
  (`/Users /Volumes /private /tmp /var/folders`) is only the list of bind sources translated into that mount, and
  **nothing narrows it: no setting, no environment variable** (`crates/kiri/src/daemon/api.rs:940`, v0.2.0). Proof run
  here: `docker run -v /mnt/mac:/h alpine ls /h` lists the Mac's `/`, and `touch /h/tmp/x` writes to the Mac's `/tmp`
  as the user. So any container the Docker API will start, or any container with `CAP_SYS_ADMIN` that mounts the
  `kiri-mac` virtiofs itself, reads and writes every file the user owns: `~/IuRoot` (company code, the VPN config,
  the token minters' state), `~/.ssh`, `~/.claude`, `~/.config`, 1Password's group container. Colima's VM mounts four
  listed paths, narrowed on 2026-11-14 for the fseventsd leak (commit 7d286b9). The always-on stack here is the company
  VPN container (`NET_ADMIN`, `/dev/net/tun`), the dashboard and token minters with bind mounts from the home
  directory: the opposite of the isolation Colima now has.
- **A young project.** Repository created 2026-11-02, five releases in eight days, 59 open issues, one author for
  most of 86 commits. It ships a daemon that binds `*:80` and `*:443` unprivileged by default.
- **Compatibility gaps found in four hours** (table (c)): an empty named volume's root is reset to `root:root 0755` at
  every mount, which breaks linewatch's `chown`-then-run-as-`app` pattern on first start.

Where kiri is good, and the case that would change this: sleep and wake. A stopped VM is gone in 60 s and the next
command wakes it in 0.4 s; a stopped compose project is healthy again in 6 s. That is worth having for a personal
stack that is idle most of the day and has no company containers on the same VM. It is not the question now.

**Apple's container** (table (f)): idle cost is 17 MiB of services and no VM; one VM per container, nothing held when no
container runs, and a container's VM gives nothing back while it runs (662 MiB at rest, 4240 MiB after a 2 GiB
allocation, 4241 MiB ten minutes later). It starts a container in 0.7 to 3.4 s. It has no restart policy, no
healthcheck, no `depends_on`, no `--device`, and "internal" means host-only. It publishes ports on 127.0.0.1 and
creates tun devices with `NET_ADMIN`. **Yes for containers that run and exit or are used rarely** (the tools
`docker run --rm` is used for): they cost nothing between uses, and its bind mounts are per container (`-v`). **No for
the always-on stack**, a compose stack and anything that needs a restart policy.

## Measurements

Host: Mac mini, macOS 26.7.2, 32 GiB. kiri v0.2.0 (arm64, Developer ID, notarized, stapled; tarball sha256 checked
against the release's `SHA256SUMS`), `KIRI_MEMORY_MIB=2048` (4096 for the first run of (a), the allocation did not fit
otherwise), 2 CPUs. Footprint = `top -l 1 -pid <pid> -stats pid,mem` of the VM's Virtualization XPC process.

### (a) Memory returned while running

One small container (`sleep`) keeps the VM awake; a second allocates and exits.

| Runtime | Rest | Peak | +2 min | +10 min | Within 500 MiB of rest? |
|-|-|-|-|-|-|
| kiri, ceiling 4096, 2048 MiB allocated | 158 | 2232 | 2232 | 2234 | **no** (+2076) |
| kiri, ceiling 2048, 1536 MiB allocated | 121 | 1662 | 1663 | 1663 | **no** (+1542) |
| Colima (same stack, not rerun) | 2062 MiB now, at a 2 GiB ceiling for about 1.05 GiB of containers; Lima never drives the balloon | | | | no, by construction |

Guest side during the first run: `free -m` total 4001, used 3908, free 81 at rest and at the peak. The balloon held the
guest at "used plus headroom" and the host never took the pages back.

### (b) Sleep and wake

| | kiri | Colima |
|-|-|-|
| Last container's exit to no VM process | 60.3 s (idle timer 60 s); 302.2 s right after a `compose build` (its BuildKit container is paused and stopped at 300 s idle first) | n/a, never sleeps |
| `docker ps` from asleep | 0.1 s, answered by the daemon, the VM stays off | n/a |
| `docker run --rm alpine true` from asleep | 0.4 s | start of the VM 12 to 26 s (brief) |
| A stopped compose project (mariadb, healthcheck) from asleep to healthy | 6.1 s | n/a |

### (c) Our compose shapes (copies under other project names and ports)

| Shape | Result |
|-|-|
| vps dev mariadb: healthcheck, named volume, loopback port | **pass.** `up --wait` 10.3 s, healthy, SQL round trip, banner read from the Mac on 127.0.0.1:23306 |
| linewatch: build, healthcheck, named volume, loopback port | **pass with a workaround, fail without.** Build and start 43.7 s cold, healthy, `/health` 200 from the Mac. First start fails: `SQLiteError: unable to open database file, code: SQLITE_CANTOPEN (src/db/client.ts:130)`. Cause: the root of an **empty** named volume is reset to `root:root 0755` on every mount, so linewatch's `chown app` (uid 999) is gone before the app starts; with any file in the volume (`.keep`) the chown persists. |
| `internal: true` network, outside only through a proxy | **pass.** Direct from the client: `wget: can't connect to remote host (1.1.1.1): Network unreachable`; through the proxy container: the example.com page, exit 0 |
| `NET_ADMIN` + `/dev/net/tun`, creates a tun device | **pass.** `tun0 … <NO-CARRIER,POINTOPOINT,MULTICAST,NOARP,UP>` and `TUN_OK` |
| `restart: unless-stopped` across a daemon restart | **pass.** Start counter 1 → 2: the daemon brings it back (and boots the VM). A container with the default policy `no` is stopped by a daemon restart and stays down. |
| `restart: unless-stopped` across a VM sleep | **cannot sleep while it runs:** the VM stayed awake for 150 s with the container running, by design (any running container pins it). A user `stop` (exit 137) stays stopped across a daemon restart; `start` from asleep works (counter 3). |

### (d) Bind-mount speed (virtiofs, `kiri/trial/bindbench.py`, python:3.13-alpine, same APFS volume, two runs each)

512 MiB sequential file and 2000 files of 4 KiB. Reads are partly guest page cache.

| | seq write MiB/s | seq read MiB/s | small create /s | small read /s |
|-|-|-|-|-|
| kiri | 1099, 1075 | 2115, 2242 | 1810, 1234 | 2218, 2651 |
| Colima | 605, 559 | 1596, 1438 | 1442, 1232 | 2435, 1924 |
| Apple's container | 541, 580 | 1096, 886 | 1167, 995 | 1893, 1474 |

Colima's directory is a scratch subdirectory of its one non-company writable mount; kiri's and Apple's are under
`~/.local/state/kiri-trial`. kiri is ahead on writes, level on small files.

### (e) What kiri installed and opened

No sudo, no `kiri setup` (it edits the shell profiles, which here are symlinks into this repo, and
`~/.docker/config.json`; its flags to skip that do not skip the profile edit), no Kiri UI (the only code that checks for
updates). What exists:

- `~/.local/share/kiri/0.2.0/Kiri.app` (the verified copy), `~/.kiri/{run,logs,files}`, an empty `~/Kiri` directory (the
  Finder mount target; the mount itself is skipped with `KIRI_NO_FINDER=1`), the docker context `kiri`.
- LaunchAgents: ours, `com.jkrumm.kiri` and the sampler `com.jkrumm.kiri-sample`. No helper, no LaunchDaemon, no
  `/etc/resolver`, no `/var/run/docker.sock`, no `/usr/local/bin/kiri`; shell profiles byte-identical.
- Listening: `*:47080` and `*:47443` (IPv4 and IPv6 wildcard: the `*.kiri.localhost` domain routers. **Default is `*:80`
  and `*:443`, started by the daemon with no root and no opt-in**; there is no off switch, only the ports
  `KIRI_HTTP_PORT` and `KIRI_HTTPS_PORT`, moved here), `127.0.0.1:47391` (image mirror for builds), UDP
  `127.0.0.1:53535` (the `*.kiri.local` resolver, unused without `/etc/resolver`). Published container ports bind as
  the compose file says (`127.0.0.1:23306`). The CA is not trusted (`trusted=false`).
- Narrowing `MAC_SHARES`: **no setting.** See the verdict.

### (f) Apple's container 1.7.1

Signed installer pkg (Developer ID Installer, Apple Inc., notarized, sha256 pinned), expanded and run from
`~/.local/share/apple-container` with `container system start --app-root … --install-root …`: no sudo, nothing in
`/usr/local`. The service ran only inside the trial and was stopped.

The seven readings of step 4:

| # | Reading | Result |
|-|-|-|
| 1 | Footprint of its services, no container running | **17 MiB** (apiserver 5, four plugins 3 each) at 60 s and at 5 min after the start, 22 MiB after the trial's containers. An earlier run read 725 MiB in the apiserver right after the first start: that was the kernel install and image pulls, 140 MiB once idle. |
| 2 | Start time of `alpine true` | **0.7, 1.0, 6.1 s** in the first run (the 6.1 s fetched the init image), **3.3, 3.4, 3.2 s** in the second; unexplained, both with the image local |
| 3 | One long-running container (mariadb 11.4, `-m 4G`): rest, and 10 min after a 2 GiB allocation ended | **662 MiB at rest, 4240 MiB at the peak, 4241 MiB 10 min later** (guest: 183 MiB used, 3.8 GiB free). The container's VM keeps everything it touched, up to its `-m`; nothing is returned while it runs (Apple's documentation says the same: memory returns when the container exits). The helper process `container-runtime-linux` is 20 MiB and not the VM; the VM is a Virtualization XPC process. |
| 4 | Port on 127.0.0.1 reachable from the Mac | **yes**, `-p 127.0.0.1:23307:3306`, banner `11.4.13-MariaDB-ubu2404` read from the Mac |
| 5 | Tun device | **yes with `--cap-add CAP_NET_ADMIN`** (`/dev/net/tun` exists in the guest, TUNSETIFF returns `TUN_OK`); without it `PermissionError: [Errno 1] Operation not permitted`. busybox `ip` has no `tuntap`. |
| 6 | Bind-mount figures | seq write 541, 580 MiB/s; seq read 1096, 886; small create 1167, 995 /s; small read 1893, 1474 /s (an earlier run under load: 492 to 504, 570 to 595, 593 to 832, 830 to 845) |
| 7 | Compose keys with no flag | **no `restart`, no `health*`, no `depends_on`, no `--device`** (`run --help` has none); **`internal` is `network create --internal` = "Restrict to host-only network"**, which is not "no route outside"; `cap-add`, `publish`, `network`, `-m`, `-c`, `-v` exist. `mount -t tmpfs` inside a container is refused (`permission denied`: no `CAP_SYS_ADMIN` by default). |

Not part of the seven: image names must be fully qualified (`docker.io/library/…`); the first `system start` downloads a
kernel; there is no compose (apple/container issue 1846).

## What a move would cost (for completeness; the verdict is no)

kiri: `kiri import` reads OrbStack and Docker Desktop, not Colima, so images go through `docker save | docker load`
and volumes through a `tar` in a throwaway container, per volume (linewatch needs the `.keep` workaround on first
start); every `docker` command needs the `kiri` context or the `/var/run/docker.sock` LaunchDaemon (needs sudo);
company containers and the VPN would sit under the whole-Mac share. Apple's container: no compose, so every project
becomes a script of `container run` lines without restart, healthcheck or ordering.

## The 48-hour reading

**Not completed: the 48 hours ran 4 h 50 min.** The mariadb copy started at 2026-11-14T19:21Z; the mini was shut
down and rebooted at 2026-11-15 01:11 local (00:11Z, `engine shutting down signal=15`, then `the VM stopped
unexpectedly`). The copy has the default restart policy, so the daemon, which came back at 00:28Z under its
LaunchAgent, left it stopped and the VM asleep for the rest of the window (172 of 192 samples read `asleep`, health
stale at `unhealthy`). I did not restart it for another 48 hours: an idle database cannot move the verdict, which rests
on table (a).

What the 20 samples while it ran (`com.jkrumm.kiri-sample`, every 15 minutes, `~/.local/state/kiri-trial/mariadb-sample.log`)
say: the VM's footprint sat at **356 to 375 MiB** (365 at the first, 366 at the last), the daemon at 10 to 19 MiB RSS,
health `healthy`, restart count 0. That is the idle working set of one mariadb with no load, and it never fell: the
largest value came in the first hour. The container log holds only two benign warnings (`io_uring_queue_init() failed
with EPERM`, `/sys/fs/cgroup/…/memory.pressure not writable`). Unclean stop at the reboot: exit 255, no
`Shutdown complete` line, as for any container whose VM disappears.

## Removal

Done at the end of the trial (2026-11-16): `make kiri-teardown` (agent, sampler, docker context, `~/.local/share/kiri`,
`~/.kiri` with the mariadb copy's volume), `make container-teardown` (done earlier), the download directories
`~/kiri-trial-dl` and `~/container-trial-dl`, and the empty `~/Kiri`. Kept: the raw logs in `~/.local/state/kiri-trial/`.
Nothing system-wide was ever installed, so nothing system-wide is removed.
