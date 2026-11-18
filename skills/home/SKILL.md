---
name: home
allowed-tools: Bash(home --help *)
description: Control and diagnose Apple Home (HomeKit) — lights, outlets, sensors, scenes, automations, accessories that show "No Response" — via the home CLI over HomeClaw on the mini. Use when the user mentions Apple Home, HomeKit, Home app, a scene ("Chill", "Gute Nacht"), turning lights on/off, a room (Wohnzimmer, Schlafzimmer, Bad, Flur), motion sensors, Hue, Eve, Meross, the dog-alone lighting, or broken/missing smart-home devices. For the router itself use `router`; for the internet line's history use the Argo Line page.
---

# Home — Apple Home via HomeClaw

home (repo `~/SourceRoot/home`, `make install` → `~/.local/bin/home`) wraps
`homeclaw-cli`. On the mini it runs locally; elsewhere it SSHes to the mini.
JSON when piped, human output on a TTY.

Verbs, live from the CLI (if you see the command and not its output, run it):

!`home --help 2>&1 || echo "home is not on this machine"`

The status verb is climate and presence, doctor is device health ("is something broken"). Start with `home device-map` (rooms, semantic types, aliases) before addressing an accessory by name; `home list`, `get`, `set`,
`search`, `events` and `automations` pass through to `homeclaw-cli` (`home help <subcommand>` for its flags). `home set` takes
`power`, `brightness 0-100`, `color_temperature` or `target_temperature`; `--dry-run` validates without actuating.

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
