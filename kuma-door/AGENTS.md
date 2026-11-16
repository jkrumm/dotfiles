# kuma-door

**Kuma door** (`kuma-door/`, `com.jkrumm.kuma-door`, `127.0.0.1:8795`) — the one
tailnet port through which the homelab's Uptime Kuma pulls the mini's service
health. `GET /h/<name>` relays the loopback URL that `kuma-door/registry.json`
maps to `<name>` and returns the upstream status with a body capped at 4 KiB;
GET/HEAD only, nothing from the request reaches the upstream. Reachable by
`tag:homelab` only (ACL grant + `tailscale serve` row, both in dotfiles-private).
- **Add a service:** edit `registry.json` (`name`, loopback `url`, Kuma `title`),
  then `make kuma-door-restart kuma-door-gen`; commit the generated
  `homelab/uptime-kuma/monitors.mini-door.generated.yaml` and run homelab's
  `sync.py --extra-config`. Monitors are generated, never hand-edited.
- `make kuma-door-setup` / `-restart` / `-teardown` / `-gen` / `-check` / `-test`;
  `-check` proves the door, the serve row and that the generated file is current.
- Push stays for jobs and the composite; the door carries service health only. Its liveness is a heartbeat `services` component.
