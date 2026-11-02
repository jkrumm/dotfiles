---
name: home
description: Control and diagnose Apple Home (HomeKit) — lights, outlets, sensors, scenes, automations, accessories that show "No Response" — via the `home` CLI over HomeClaw on the mini. Use when the user mentions Apple Home, HomeKit, Home app, a scene ("Chill", "Gute Nacht"), turning lights on/off, a room (Wohnzimmer, Schlafzimmer, Bad, Flur), motion sensors, Hue, Eve, Meross, the dog-alone lighting, or broken/missing smart-home devices. For the router itself use `router`; for the internet line use linewatch.
---

# Home — Apple Home via HomeClaw

`home` (repo `~/SourceRoot/home`, `make install` → `~/.local/bin/home`) wraps
`homeclaw-cli`. On the mini it runs locally; elsewhere it SSHes to the mini.
JSON when piped, human output on a TTY.

```bash
home doctor                      # not responding, low battery, drop-offs (24 h)
home scenes                      # user scenes: name<TAB>id
home trigger "Chill"             # run a scene
home device-map                  # LLM-oriented map: rooms, semantic types, aliases — read this first
home list --room Wohnzimmer      # accessories with state
home get "Sofa"                  # one accessory, all characteristics
home set "Sofa" power true       # power | brightness 0-100 | color_temperature | target_temperature …
home set "Sofa" brightness 40 --dry-run   # validate without actuating
home search "bett"
home automations                 # list; `automations get "<name>"` for detail
home events --since 1d           # characteristic changes, reachability, scene triggers
home events --type reachability_change --since 7d
home help <subcommand>           # full homeclaw-cli help
```

Everything not `scenes|trigger|doctor` passes straight to `homeclaw-cli`.

## Rules

- **Names are ambiguous.** Several rooms reuse names (`Bett`, `Esstisch`,
  `Küche`, `Schreibtisch` exist twice). Resolve via `home device-map` or
  `home list --room …` and use the accessory id when a name matches twice.
- **Ask before** anything the owner didn't request: deleting scenes,
  removing accessories, editing or disabling automations. Use `--dry-run`
  first and show the result.
- A read that touches an unreachable accessory fails with `live refresh
  failed`; retry with `--no-refresh` for last-known values.
- `home: HomeClaw unreachable` means the HomeClaw app on the mini is not
  running or the GUI session logged out — say so; don't retry-loop.

## Diagnosing "No Response"

1. `home doctor` — which accessories, which brand, bridged or not.
2. Classify: several brands → network/hub; one brand → that vendor's
   credentials/bridge; one device → device, battery, range.
3. Wi-Fi accessories (Meross, Leedarson/Wi-Fi bulbs) after the router swap:
   wrong SSID/password/security or steered to 5 GHz. Check the device is
   associated with `router` (`routerctl clients`); re-provision on the
   2.4 GHz network.
4. Thread accessories (Eve) don't store Wi-Fi credentials: power-cycle 5 min,
   wait 10, check the Apple TV is the hub (Home → Home Hubs & Bridges).
5. Bridged (via Philips Hue Bridge): the bulb is unpowered or removed from
   the Hue app — fix in the Hue app, not in Apple Home.

Full playbook with sources: `~/SourceRoot/home/docs/research/2026-11-02-no-response-after-router-swap.md`.
