---
description: Apple developer setup for every app of ours — what lives where (portal, 1Password, the mini), which credential does what, the order of a new app's one-time portal steps, and the traps that cost hours on Iris (App Group, Push, headless signing, tunnel, lock). Read before touching an Apple signing, provisioning, APNs, TestFlight or Sparkle problem, or before starting a new iOS/macOS app.
---

# Apple signing — one team, many apps

> - **One paid team for everything.** Team id: `op://mini/apple-developer/team-id`. Never in a tracked file.
> - **Anything an API key cannot do is the Account Holder's, once per app, in the portal:** registering an App Group,
>   attaching it to an App ID, a Developer ID certificate, the App Store Connect app record.
> - **Headless on the mini = `secrets-run` + the ASC Team key + `-allowProvisioningUpdates`.** Never `op`, never Xcode's account.
> - **A provisioning error that names an entitlement means the portal lacks that capability on that App ID**, not a code bug.

## Credentials: what, where, used for

All in the 1Password item `op://mini/apple-developer`, read on the mini with `secrets-run read` (seeded via `dotfiles-private/headless.refs`).

| Field | What it is | Used for |
|-|-|-|
| `team-id` | the paid team's id | `DEVELOPMENT_TEAM`, ExportOptions `teamID` |
| `asc-key-p8`, `asc-key-id`, `asc-issuer-id` | App Store Connect **Team** API key (Users and Access > Integrations; an individual key cannot do provisioning or notarytool) | `xcodebuild -allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID` (creates App IDs, profiles, devices), TestFlight upload, `notarytool` |
| `apns-key-p8`, `apns-key-id` | APNs **auth key** (token auth) | the server's APNs notifier (`APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_TOPIC` = bundle id). The key is not per environment (sandbox vs production is the token's host; unverified for production until the first TestFlight build). |
| Sparkle EdDSA key | Mac update signing | private key in the mini's login keychain, backup file `~/.local/state/apple-developer/sparkle-ed25519.key` (0600, outside every repo); the 1Password copy is the owner's |

Not credentials, but needed: an Apple Development identity in the mini's login keychain (cloud-managed by `-allowProvisioningUpdates`), a Developer ID Application certificate for the Mac (Account Holder creates it).

- 1Password flattens the `.p8` newlines into spaces. Rebuild real newlines and 64-character body lines before `-authenticationKeyPath` (Iris: `pem_normalize` in `scripts/device-lib.sh`; the server: `normalizePem`). Write it to a `mktemp` file, mode 0600, delete it with a `trap` on `EXIT`.
- "Certificates (0)" under Push Notifications in the portal is irrelevant: auth-key APNs needs no per-App-ID certificate.

## A new app: the one-time portal steps (Account Holder, ~5 minutes)

Do these before the first device build; the API key does the rest. Portal: developer.apple.com > Certificates, Identifiers & Profiles.

1. **App Group** (if the app shares data between app and extensions): the filter top right > App Groups > **+** > App Groups > description, identifier `group.<bundle id>`. Register it first.
2. **App IDs:** with `-allowProvisioningUpdates` the first build creates them (named `XC <bundle id>`). Then, **for each App ID that needs the group** (app and every extension that reads it): open it > App Groups > Configure/Edit > tick the group > Continue > Save.
3. **Push Notifications** only on the App ID that holds `aps-environment` (the main app; widgets and notification-service extensions do not need it).
4. **App Store Connect app record** (for TestFlight upload): My Apps > + > the bundle id.
5. **Mac outside the store:** a Developer ID Application certificate, then notarization with the same Team key.

An entitlement in the tracked `*.entitlements` that the portal's App ID lacks fails the whole build with "Provisioning profile … doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" (or `aps-environment`). Fix the portal, rerun; never strip the key from the tracked file. The Personal Team fallback (free, no Push, no App Groups) strips them in derived copies only.

## Traps (all hit on Iris, 2026-11)

| Trap | Fix |
|-|-|
| App Group missing: three-target build failure | portal steps 1-2 above; nothing in code or the API key helps |
| `devicectl list devices` shows the phone `disconnected` but `available (paired)` | the tunnel comes up on first use: accept `disconnected`, skip only `unavailable`; the phone must be awake/unlocked for `launch`, not for install |
| Two Apple jobs at once | every xcodebuild/devicectl/archive runs under `lockf -t 1800 /tmp/iris-apple.lock timeout 1500 …`; a release job (notarization up to 40 min) holds it, a 900 s wait times out |
| APNs sandbox vs production | Xcode Debug builds use the sandbox host and tokens; TestFlight/App Store builds use production: `apnsEnv` follows the channel (`#if DEBUG`) |
| `devicectl device copy from --domain-type appGroupDataContainer` refuses a file at the container root | only `Library`, `Documents`, `tmp` are readable: prove a write by a device-log line, not by the file |
| No device log access without root | the app's own telemetry relay (HyperDX, `agw otel`) is the log; add an event for anything you need to prove |
| Build number | `CFBundleVersion` from `git rev-list --count HEAD`, never committed |

## Proving an entitlement on the phone

```bash
codesign -d --entitlements :- <Iris.app or .appex> | plutil -convert json -o - -     # the group, aps-environment, keychain groups
```

then an app event that reads `containerURL(forSecurityApplicationGroupIdentifier:)` (Iris: `widget.container`, `available=true`) and one that shows a real write (`widget.snapshot saved=true`).

## Where the details live

Per-repo recipes stay in the repo (Iris: `AGENTS.md` "Device", skills `device`, `apple-dev`, `docs/research/2026-11-04-apple-paid-team.md` for the TestFlight / Developer ID / Sparkle design). This file is what holds for every app. The global skill `apple-signing` points here.
