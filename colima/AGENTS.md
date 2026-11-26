# colima

`make colima-{start,stop,restart,status}` — never bare `colima stop` or `brew
services restart colima`, both fight the supervised boot path.
`colima-restart` applies `COLIMA_CPU`/`COLIMA_MEMORY` (mini **4/4/60**, MacBook
**2/4/30**; ceilings; disk grows only via recreate; the mini's 4 GB is the Memory budget in
`docs/devhost-health.md`, applied by `make colima-restart`, never by hand). On the mini the VM mounts
only `colima/mounts.mini.txt` (not `$HOME`): a new bind mount elsewhere shows an empty directory, so add its path there
first. Run `colima-restart` from the main checkout: the plist records the checkout it ran from. The default VM's
resolver is **derived at every start** (`colima/vm-dns-guest.sh`, an `after-boot` provision step written by
`colima/apply-provision.sh`; `colima/vm-dns.sh apply|check` on a running VM; the heartbeat's `colima` probe fails when no name
resolves in it). The heartbeat's probe also fails when the running VM's mounts differ from `colima/mounts.mini.txt` (`colima/mounts-check.sh`): a list change lands at the next VM start only. **The mini runs one VM, always on** (the VPN and the import dashboard share it; an out-of-memory kill in the guest means `COLIMA_MEMORY=3` (then 4), never a second VM), and `make colima-restart` returns before the VM is down. Full model — the inverted
`KeepAlive` repair, brew silently regenerating the plist on every `brew
services start/restart`/`brew upgrade colima`, the `sh.brew.*` rename,
`kickstart -k` not re-reading the plist, `com.colima.docker-socket` for the
Raycast Docker extension: `docs/remote-dev.md` → *launchd on the dev host*.
